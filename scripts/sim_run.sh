#!/usr/bin/env bash

# Create and run the PX4 simulator containers.
# Build the images first with ./scripts/sim_build.sh.
# Pressing any key in this window removes the containers again.
set -euo pipefail

# Find the scripts folder and the top folder of this project.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Keep these names in one place so cleanup only removes this project's containers.
SERVICES=("simulation" "drone" "ground")
SIMULATION_IMAGE="dronesimenv/simulation:latest"
DRONE_IMAGE="dronesimenv/drone:latest"
GROUND_IMAGE="dronesimenv/ground:latest"
# These flags stop cleanup from running too early or running twice.
CLEANUP_DONE=false
CLEANUP_ENABLED=false

is_wsl2() {
    # WSL2 writes the word "microsoft" in this system file.
    grep -qi microsoft /proc/version 2>/dev/null
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

require_xterm() {
    # xterm opens one small terminal window for each container.
    # It must be installed on the Ubuntu or WSL2 host, not in Docker.
    command -v xterm >/dev/null 2>&1 || {
        echo "ERROR: xterm is not installed or is not on PATH." >&2
        echo "Install it on the host, then run this script again:" >&2
        echo "  sudo apt-get update && sudo apt-get install -y xterm" >&2
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

    for image in "${SIMULATION_IMAGE}" "${DRONE_IMAGE}" "${GROUND_IMAGE}"; do
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

    # The simulation and drone containers need extra shared memory.
    if [[ "${service}" == "simulation" || "${service}" == "drone" ]]; then
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
    local workdir="$3"

    # xterm is on the host. tmux is inside the container.
    # -A makes a new tmux session or joins the old one with the same name.
    xterm -T "${title}" -e \
        docker exec -it "${service}" \
        tmux new-session -A -s "${service}" -c "${workdir}" &
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
    require_xterm
    configure_x11_access

    # Delete only old project containers before making fresh ones.
    CLEANUP_ENABLED=true
    remove_project_containers
    run_service "simulation" "${SIMULATION_IMAGE}" \
        "${PROJECT_ROOT}/simulation/simulation_ws/src" \
        "/DroneSimEnv/simulation_ws/src"
    run_service "ground" "${GROUND_IMAGE}" \
        "${PROJECT_ROOT}/ground/ground_ws/src" \
        "/DroneSimEnv/ground_ws/src"
    run_service "drone" "${DRONE_IMAGE}" \
        "${PROJECT_ROOT}/drone/drone_ws/src" \
        "/DroneSimEnv/drone_ws/src"

    # Give Docker a moment before the new xterm windows enter the containers.
    sleep 3
    open_terminal "drone" "Drone (ROS 2)" \
        "/DroneSimEnv/drone_ws"
    open_terminal "simulation" "Simulation (PX4)" \
        "/DroneSimEnv/simulation_ws"
    open_terminal "ground" "Ground (QGC)" \
        "/DroneSimEnv/ground_ws"

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
