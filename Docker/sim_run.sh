#!/usr/bin/env bash

# Create and run the PX4 simulator containers.
# Build the images first with ./sim_build.sh.
# This file never builds images, so starting and building stay separate.
set -euo pipefail

# Find the Docker folder and the top folder of this project.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Keep these names in one place so every command manages the same containers.
SERVICES=("companion" "drone_sim" "ground")
DRONE_SIM_IMAGE="dronesimenv/drone_sim:latest"
COMPANION_IMAGE="dronesimenv/companion:latest"
GROUND_IMAGE="dronesimenv/ground:latest"

is_wsl2() {
    # WSL2 writes the word "microsoft" in this system file.
    grep -qi microsoft /proc/version 2>/dev/null
}

usage() {
    cat <<EOF
Usage:
  $0 up [--no-terminal]
  $0 stop
  $0 down
  $0 logs [service]
  $0 shell <service>
  $0 status

Services:
  companion
  drone_sim
  ground

Commands:
  up                      Recreate and start the three containers.
  up --no-terminal        Do not open terminal windows after starting.
  stop                    Stop containers but keep them.
  down                    Stop and remove this project's containers.
  logs [service]          Follow logs for one service or all services.
  shell <service>         Open bash inside a running container.
  status                  Show this project's container status.
EOF
}

is_valid_service() {
    local service="$1"
    local candidate

    for candidate in "${SERVICES[@]}"; do
        [[ "${candidate}" == "${service}" ]] && return 0
    done

    return 1
}

require_docker() {
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

container_is_running() {
    # Ask Docker for a simple true or false answer.
    [[ "$(docker container inspect --format '{{.State.Running}}' "$1")" == "true" ]]
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
            echo "Removing old ${service} container..."
            docker rm --force "${service}" >/dev/null
        fi
    done
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
        echo "Container '${service}' is running. Open it with: $0 shell ${service}"
    fi
}

command_up() {
    local terminals=true

    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            --no-terminal) terminals=false ;;
            *)
                echo "ERROR: unknown up option: $1" >&2
                usage >&2
                exit 1
                ;;
        esac
        shift
    done

    # Check everything before deleting old containers and making new ones.
    require_docker
    require_images
    configure_x11_access
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

    echo "DroneSimEnv is running."
    if [[ "${terminals}" == true ]]; then
        open_terminal "companion" "Companion (ROS 2)"
        open_terminal "drone_sim" "Drone Sim (PX4)"
        open_terminal "ground" "Ground (QGC)"
    fi
}

command_stop() {
    local service

    require_docker
    # Stopping keeps the container so it can be inspected later.
    for service in "${SERVICES[@]}"; do
        if container_exists "${service}"; then
            if container_is_running "${service}"; then
                echo "Stopping ${service}..."
                docker stop "${service}" >/dev/null
            else
                echo "${service} is already stopped."
            fi
        fi
    done
}

command_down() {
    # Down removes containers, but never removes images or project files.
    require_docker
    remove_project_containers
}

command_logs() {
    local service
    local -a log_pids=()

    require_docker
    if [[ "$#" -eq 1 ]]; then
        is_valid_service "$1" || {
            echo "ERROR: unknown service: $1" >&2
            exit 1
        }
        docker logs --follow "$1"
        return
    fi

    if [[ "$#" -ne 0 ]]; then
        echo "ERROR: logs accepts zero or one service name." >&2
        exit 1
    fi

    # Start one log reader per container and add its name to every log line.
    for service in "${SERVICES[@]}"; do
        if container_exists "${service}"; then
            docker logs --follow "${service}" 2>&1 | sed -u "s/^/[${service}] /" &
            log_pids+=("$!")
        fi
    done

    [[ "${#log_pids[@]}" -gt 0 ]] || {
        echo "ERROR: no DroneSimEnv containers exist." >&2
        exit 1
    }

    trap 'kill "${log_pids[@]}" 2>/dev/null || true' INT TERM
    wait "${log_pids[@]}" || true
}

command_shell() {
    [[ "$#" -eq 1 ]] || {
        echo "ERROR: shell requires exactly one service name." >&2
        exit 1
    }
    is_valid_service "$1" || {
        echo "ERROR: unknown service: $1" >&2
        exit 1
    }

    require_docker
    docker exec -it "$1" /bin/bash
}

command_status() {
    local service

    require_docker
    # Show a row even for a container that has not been created yet.
    for service in "${SERVICES[@]}"; do
        if container_exists "${service}"; then
            docker container inspect \
                --format '{{.Name}}\t{{.Config.Image}}\t{{.State.Status}}' \
                "${service}"
        else
            printf '%s\t%s\t%s\n' "${service}" "-" "not created"
        fi
    done
}

main() {
    local command="${1:-}"
    if [[ -n "${command}" ]]; then
        shift
    fi

    case "${command}" in
        up) command_up "$@" ;;
        stop) [[ "$#" -eq 0 ]] || { usage >&2; exit 1; }; command_stop ;;
        down) [[ "$#" -eq 0 ]] || { usage >&2; exit 1; }; command_down ;;
        logs) command_logs "$@" ;;
        shell) command_shell "$@" ;;
        status) [[ "$#" -eq 0 ]] || { usage >&2; exit 1; }; command_status ;;
        -h|--help|help) usage ;;
        *)
            [[ -n "${command}" ]] && echo "ERROR: unknown command: ${command}" >&2
            usage >&2
            exit 1
            ;;
    esac
}

main "$@"
