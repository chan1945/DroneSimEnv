#!/usr/bin/env bash

# Create and run the PX4 simulator containers.
# Build the images first with ./tools/sim_build.sh.
# Pressing any key in this window removes the containers again.
set -euo pipefail

# Find the tools folder and the top folder of this project.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Keep these names in one place so cleanup only removes this project's containers.
SERVICES=("simulation" "drone" "ground")
# These tags must match the images made by sim_build.sh.
CUDA_VERSION="13.3.0"
SIMULATION_IMAGE="dronesimenv/simulation:cuda${CUDA_VERSION}"
DRONE_IMAGE="dronesimenv/drone:cuda${CUDA_VERSION}"
GROUND_IMAGE="dronesimenv/ground:cuda${CUDA_VERSION}"
# These flags stop cleanup from running too early or running twice.
CLEANUP_DONE=false
CLEANUP_ENABLED=false
# WORLD_NAME identifies the selected SDF world.
WORLD_NAME=""
# MODEL_NAME identifies the selected Gazebo drone model directory.
MODEL_NAME=""
# AIRFRAME_ID overrides PX4's model-name airframe lookup when supplied.
AIRFRAME_ID=""
# WORLD_FILE is the chosen host-side world SDF file.
WORLD_FILE=""
# MODEL_DIR is the chosen host-side model directory.
MODEL_DIR=""

# Show the required resource names and the optional airframe override.
usage() {
    cat <<EOF
Usage: $0 --world NAME --model NAME [--airframe ID]

World: simulation/simulation_ws/src/simulation_resources/worlds/NAME/NAME.sdf
       or simulation/simulation_ws/src/simulation_resources/worlds/NAME.sdf
Model: simulation/simulation_ws/src/simulation_resources/drone_models/NAME/model.sdf

PX4 chooses a matching built-in airframe by model name unless --airframe is set.
EOF
}

# Parse CLI options before Docker creates or removes any containers.
parse_options() {
    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            --world|--model|--airframe)
                # The option name determines which selected value receives its argument.
                local option="$1"
                [[ "$#" -ge 2 && -n "$2" && "$2" != --* ]] || {
                    echo "ERROR: ${option} requires a value." >&2
                    usage >&2
                    return 1
                }
                case "${option}" in
                    --world) WORLD_NAME="$2" ;;
                    --model) MODEL_NAME="$2" ;;
                    --airframe) AIRFRAME_ID="$2" ;;
                esac
                shift 2
                ;;
            -h|--help)
                usage
                return 2
                ;;
            *)
                echo "ERROR: unknown option: $1" >&2
                usage >&2
                return 1
                ;;
        esac
    done

    if [[ -z "${WORLD_NAME}" || -z "${MODEL_NAME}" ]]; then
        echo "ERROR: 월드와 드론 모델을 모두 지정해야 합니다 (--world NAME --model NAME)." >&2
        usage >&2
        return 1
    fi
}

# Resolve only simple resource names within the two expected host directories.
validate_resources() {
    # The resource root contains the world and drone model directories.
    local resource_root="${PROJECT_ROOT}/simulation/simulation_ws/src/simulation_resources"
    # The world search root contains either flat SDF files or named folders.
    local worlds_root="${resource_root}/worlds"
    # The model search root contains named model folders.
    local models_root="${resource_root}/drone_models"

    [[ "${WORLD_NAME}" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]] || {
        echo "ERROR: invalid world name: ${WORLD_NAME}" >&2
        return 1
    }
    [[ "${MODEL_NAME}" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]] || {
        echo "ERROR: invalid model name: ${MODEL_NAME}" >&2
        return 1
    }
    [[ -z "${AIRFRAME_ID}" || "${AIRFRAME_ID}" =~ ^[0-9]+$ ]] || {
        echo "ERROR: --airframe must be a numeric PX4 autostart ID." >&2
        return 1
    }

    if [[ -f "${worlds_root}/${WORLD_NAME}/${WORLD_NAME}.sdf" ]]; then
        WORLD_FILE="${worlds_root}/${WORLD_NAME}/${WORLD_NAME}.sdf"
    elif [[ -f "${worlds_root}/${WORLD_NAME}.sdf" ]]; then
        WORLD_FILE="${worlds_root}/${WORLD_NAME}.sdf"
    else
        echo "ERROR: world SDF was not found for '${WORLD_NAME}' in ${worlds_root}." >&2
        return 1
    fi

    MODEL_DIR="${models_root}/${MODEL_NAME}"
    [[ -f "${MODEL_DIR}/model.sdf" && -f "${MODEL_DIR}/model.config" ]] || {
        echo "ERROR: model.sdf and model.config were not found for '${MODEL_NAME}' in ${models_root}." >&2
        return 1
    }
}

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

    if [[ "${service}" == "simulation" ]]; then
        # PX4 selects the world and model through these environment variables.
        run_args+=(
            --env "PX4_GZ_WORLD=${WORLD_NAME}"
            --env "PX4_SIM_MODEL=gz_${MODEL_NAME}"
            --env "GZ_IP=127.0.0.1"
            # Gazebo uses these paths for model URIs and world assets.
            --env "GZ_SIM_RESOURCE_PATH=/DroneSimEnv/simulation_ws/src/simulation_resources/worlds:/DroneSimEnv/simulation_ws/src/simulation_resources/worlds/${WORLD_NAME}:/DroneSimEnv/simulation_ws/src/simulation_resources/drone_models"
        )
        if [[ -n "${AIRFRAME_ID}" ]]; then
            run_args+=(--env "PX4_SYS_AUTOSTART=${AIRFRAME_ID}")
        fi
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

# Place the selected files where PX4 v1.16 expects its Gazebo assets.
stage_simulation_resources() {
    echo "Loading world '${WORLD_NAME}' and model '${MODEL_NAME}' into PX4..."
    docker cp "${WORLD_FILE}" \
        "simulation:/DroneSimEnv/PX4-Autopilot/Tools/simulation/gz/worlds/${WORLD_NAME}.sdf"
    docker exec simulation cp -a \
        "/DroneSimEnv/simulation_ws/src/simulation_resources/drone_models/${MODEL_NAME}/." \
        "/DroneSimEnv/PX4-Autopilot/Tools/simulation/gz/models/${MODEL_NAME}/"
}

# Start PX4 in a persistent tmux window so its console and startup errors stay visible.
start_px4() {
    docker exec simulation tmux new-session -d -s simulation -n shell \
        -c /DroneSimEnv/simulation_ws
    docker exec simulation tmux new-window -t simulation -n px4 \
        -c /DroneSimEnv/PX4-Autopilot/build/px4_sitl_default/rootfs
    docker exec simulation tmux send-keys -t simulation:px4 \
        /DroneSimEnv/PX4-Autopilot/build/px4_sitl_default/bin/px4 Enter
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
    # A help request exits before checking Docker or altering containers.
    parse_options "$@" || {
        [[ "$?" -eq 2 ]] && return 0
        return 1
    }
    validate_resources

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
    stage_simulation_resources
    start_px4

    # Give Docker a moment before the new xterm windows enter the containers.
    sleep 3
    open_terminal "drone" "Drone (ROS 2)" \
        "/DroneSimEnv/drone_ws"
    open_terminal "simulation" "Simulation (PX4)" \
        "/DroneSimEnv/PX4-Autopilot/build/px4_sitl_default/rootfs"
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
