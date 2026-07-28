#!/usr/bin/env bash

# Create and run the PX4 simulator containers.
# Build the images first with ./sim_build.sh.
# Pressing any key in this window removes the containers again.
set -euo pipefail

# Find the Docker folder and the top folder of this project.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Keep these names in one place so cleanup only removes this project's containers.
SERVICES=("companion" "drone_sim" "ground")
DRONE_SIM_IMAGE="dronesimenv/drone_sim:latest"
COMPANION_IMAGE="dronesimenv/companion:latest"
GROUND_IMAGE="dronesimenv/ground:latest"
# These flags stop cleanup from running too early or running twice.
CLEANUP_DONE=false
CLEANUP_ENABLED=false

is_wsl2() {
    # WSL2 writes the word "microsoft" in this system file.
    grep -qi microsoft /proc/version 2>/dev/null
}

configure_wsl2_terminal() {
    # WSL2 needs a terminal app before this script can open shell windows.
    # It also needs these fonts so normal text and emoji look correct.
    if command -v xfce4-terminal >/dev/null 2>&1 && \
        dpkg -s fonts-noto-cjk >/dev/null 2>&1 && \
        dpkg -s fonts-noto-color-emoji >/dev/null 2>&1; then
        return
    fi

    echo "Installing the WSL2 terminal app and fonts..."
    echo "Your password may be needed to install these packages."
    sudo apt-get update
    sudo apt-get install -y \
        xfce4-terminal \
        dbus-x11 \
        fonts-noto-cjk \
        fonts-noto-color-emoji

    # Rebuild the font list so new terminal windows can use the new fonts.
    if command -v fc-cache >/dev/null 2>&1; then
        fc-cache -fv >/dev/null 2>&1
    fi
}

configure_wsl2_locale() {
    # Tell terminal programs to use the common UTF-8 text format.
    export LANG=en_US.UTF-8
    export LC_ALL=en_US.UTF-8
}

require_docker() {
    # Stop early when Docker is missing or cannot be used.
    command -v docker >/dev/null 2>&1 || {
        echo "ERROR: Docker is not installed or is not on PATH." >&2
        exit 1
    }

    docker info >/dev/null 2>&1 || {
        echo "ERROR: Docker is not ready for the current user." >&2
        exit 1
    }
}

container_exists() {
    # Docker returns success only when a container with this exact name exists.
    docker container inspect "$1" >/dev/null 2>&1
}

require_images() {
    # Do not remove old containers until all new images are ready to use.
    local image

    for image in "${DRONE_SIM_IMAGE}" "${COMPANION_IMAGE}" "${GROUND_IMAGE}"; do
        docker image inspect "${image}" >/dev/null 2>&1 || {
            echo "ERROR: image '${image}' was not found." >&2
            echo "Run '${SCRIPT_DIR}/sim_build.sh' before starting containers." >&2
            exit 1
        }
    done
}

remove_project_containers() {
    local service

    for service in "${SERVICES[@]}"; do
        if container_exists "${service}"; then
            # Only these three exact names belong to this script.
            echo "Removing ${service} container..."
            docker rm --force "${service}" >/dev/null
        fi
    done
}

cleanup() {
    local exit_code="$?"
    local service

    # There is nothing to remove before the script starts changing containers.
    [[ "${CLEANUP_ENABLED}" == true ]] || exit "${exit_code}"

    # Run this only once, even when a signal and EXIT happen together.
    [[ "${CLEANUP_DONE}" == true ]] && exit "${exit_code}"
    CLEANUP_DONE=true
    trap - EXIT INT TERM

    echo
    echo "Stopping and removing DroneSimEnv containers..."
    for service in "${SERVICES[@]}"; do
        if container_exists "${service}"; then
            # --force stops the container first, then removes this exact name.
            docker rm --force "${service}" >/dev/null 2>&1 || \
                echo "WARNING: Could not remove ${service}." >&2
        fi
    done
    echo "DroneSimEnv containers are down."
    exit "${exit_code}"
}

configure_x11_access() {
    # X11 needs this permission before a container can show a GUI window.
    if command -v xhost >/dev/null 2>&1; then
        if ! xhost +local:docker >/dev/null 2>&1; then
            echo "WARNING: X11 access was not granted. GUI windows may not open." >&2
        fi
    else
        echo "WARNING: xhost is unavailable. GUI windows may not open." >&2
    fi
}

run_service() {
    local service="$1"
    local image="$2"
    local workspace_source="$3"
    local workspace_target="$4"
    # Put Docker options in a list. This keeps spaces in folder names safe.
    local -a run_args=(
        --detach
        --interactive
        --tty
        --name "${service}"
        --privileged
        # The three containers talk through the host network, like Compose did.
        --network host
        --ipc host
        --gpus all
        --env "QT_X11_NO_MITSHM=1"
        --env "NVIDIA_DRIVER_CAPABILITIES=all"
        --env "NVIDIA_VISIBLE_DEVICES=all"
        --volume "/tmp/.X11-unix:/tmp/.X11-unix:rw"
        # Let code changed on the host appear inside the container right away.
        --volume "${workspace_source}:${workspace_target}:rw"
    )

    # The simulator and companion need extra shared memory.
    if [[ "${service}" == "drone_sim" || "${service}" == "companion" ]]; then
        run_args+=(--shm-size 2g)
    fi

    if is_wsl2; then
        # These settings let WSLg pass graphics and sound into the container.
        run_args+=(
            --env "DISPLAY=${DISPLAY:-:0}"
            --env "WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-wayland-0}"
            --env "XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/mnt/wslg/runtime-dir}"
            --env "PULSE_SERVER=${PULSE_SERVER:-unix:/mnt/wslg/PulseServer}"
            --env "LD_LIBRARY_PATH=/usr/lib/wsl/lib"
            --env "MESA_D3D12_DEFAULT_ADAPTER_NAME=NVIDIA"
            --env "LIBGL_ALWAYS_SOFTWARE=0"
            --env "__GLX_VENDOR_LIBRARY_NAME=nvidia"
            --volume "/mnt/wslg:/mnt/wslg"
            --volume "/usr/lib/wsl:/usr/lib/wsl"
            --device "/dev/dxg:/dev/dxg"
        )
    else
        run_args+=(--env "DISPLAY=${DISPLAY:-}")
    fi

    echo "Creating and starting ${service}..."
    docker run "${run_args[@]}" "${image}" >/dev/null
}

open_terminal() {
    local service="$1"
    local title="$2"

    # Ubuntu and WSL2 normally use different terminal programs.
    if is_wsl2 && command -v xfce4-terminal >/dev/null 2>&1; then
        env GTK_THEME=Adwaita:dark xfce4-terminal \
            --title="${title}" \
            -x bash -c "docker exec -it ${service} /bin/bash" &
    elif ! is_wsl2 && command -v gnome-terminal >/dev/null 2>&1; then
        gnome-terminal \
            --title="${title}" \
            -- bash -c "docker exec -it ${service} /bin/bash" &
    else
        echo "Container '${service}' is running, but no terminal app was found."
    fi
}

main() {
    # This script has no commands or options. It always starts all containers.
    if [[ "$#" -ne 0 ]]; then
        echo "ERROR: sim_run.sh does not accept commands or options." >&2
        echo "Usage: $0" >&2
        exit 1
    fi

    require_docker
    require_images
    if is_wsl2; then
        configure_wsl2_terminal
        configure_wsl2_locale
    fi
    configure_x11_access

    # Delete only old project containers before making fresh ones.
    CLEANUP_ENABLED=true
    remove_project_containers
    run_service "drone_sim" "${DRONE_SIM_IMAGE}" \
        "${PROJECT_ROOT}/Drone_sim/drone_sim_ws/src" \
        "/DroneSimEnv/drone_sim_ws/src"
    run_service "ground" "${GROUND_IMAGE}" \
        "${PROJECT_ROOT}/Ground/ground_ws/src" \
        "/DroneSimEnv/ground_ws/src"
    run_service "companion" "${COMPANION_IMAGE}" \
        "${PROJECT_ROOT}/Companion/companion_ws/src" \
        "/DroneSimEnv/companion_ws/src"

    # Give Docker a moment before the new shell windows try to enter containers.
    sleep 3
    open_terminal "companion" "Companion (ROS 2)"
    open_terminal "drone_sim" "Drone Sim (PX4)"
    open_terminal "ground" "Ground (QGC)"

    echo "DroneSimEnv is running. Press any key in this window to stop it."
    if ! IFS= read -r -n 1 -s; then
        echo "Input closed. Stopping containers."
    fi
}

# Clean up after a key press, Ctrl+C, termination, or an unexpected error.
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

main "$@"
