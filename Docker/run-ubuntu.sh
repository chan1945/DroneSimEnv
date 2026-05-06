#!/usr/bin/env bash

# 에러가 발생하거나, 선언되지 않은 변수를 사용하거나, pipe 중간에서 실패하면 즉시 종료합니다.
set -euo pipefail

# 이 스크립트가 어느 위치에서 실행되든 compose 파일을 찾을 수 있도록
# 스크립트 자신의 디렉터리를 기준 경로로 사용합니다.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="${SCRIPT_DIR}/Dockerfile/docker-compose-ubuntu.yml"

# shell 명령으로 접속을 허용할 컨테이너 서비스 목록입니다.
SERVICES=("companion" "drone_sim" "ground")

# 사용 가능한 subcommand와 예시를 출력합니다.
usage() {
    cat <<EOF
Usage:
  $0 up
  $0 stop
  $0 down
  $0 logs
  $0 shell <service>

Services:
  companion
  drone_sim
  ground

Examples:
  $0 up
  $0 shell companion
  $0 logs
  $0 stop
  $0 down
EOF
}

# 입력받은 service 이름이 위 SERVICES 목록에 있는지 검사합니다.
is_valid_service() {
    local service="$1"

    for candidate in "${SERVICES[@]}"; do
        if [[ "${candidate}" == "${service}" ]]; then
            return 0
        fi
    done

    return 1
}

# gnome-terminal 새 창을 열고, 지정한 컨테이너에 bash로 접속합니다.
open_terminal() {
    local title="$1"
    local service="$2"
    local message="$3"

    gnome-terminal \
        --title="${title}" \
        -- bash -c "echo '${message}'; docker exec -it ${service} /bin/bash"
}

# Docker 이미지를 빌드하고 3개 컨테이너를 백그라운드로 실행합니다.
# 예전 구조처럼 여기서 logs -f를 붙잡지 않으므로 Ctrl+C로 컨테이너가 삭제되지 않습니다.
command_up() {
    echo "Starting DroneSimEnv (ubuntu)..."

    # Docker 컨테이너에서 Gazebo/QGroundControl 같은 GUI 앱을 띄울 수 있도록 X11 접근을 허용합니다.
    if ! xhost +local:docker >/dev/null 2>&1; then
        echo "WARNING: Failed to allow X11 access with xhost. GUI apps may not open." >&2
    fi

    echo "Building and starting containers..."
    docker compose -f "${COMPOSE_FILE}" up --build -d

    echo "Waiting for terminal access (3 seconds)..."
    sleep 3

    echo "Opening terminals for Companion, Drone_sim, and Ground."
    open_terminal "Companion (ROS2)" "companion" "Companion container."
    open_terminal "Drone Sim (PX4)" "drone_sim" "Drone_sim container."
    open_terminal "Ground (QGC)" "ground" "Ground container."

    echo "DroneSimEnv is running."
    echo "Use '$0 logs' to follow logs."
    echo "Use '$0 stop' to stop containers while keeping them."
    echo "Use '$0 down' to remove containers."
}

# 컨테이너를 삭제하지 않고 정지만 합니다. 이후 up으로 다시 시작할 수 있습니다.
command_stop() {
    echo "Stopping DroneSimEnv containers while keeping them..."
    docker compose -f "${COMPOSE_FILE}" stop
}

# 컨테이너와 compose 네트워크를 정리합니다. 보존이 필요 없을 때 명시적으로 사용합니다.
command_down() {
    echo "Stopping and removing DroneSimEnv containers..."
    docker compose -f "${COMPOSE_FILE}" down
}

# compose 로그를 follow 모드로 출력합니다. Ctrl+C를 눌러도 로그 보기만 종료됩니다.
command_logs() {
    docker compose -f "${COMPOSE_FILE}" logs -f
}

# 지정한 컨테이너 안으로 대화형 bash shell을 엽니다.
command_shell() {
    local service="${1:-}"

    if [[ "$#" -ne 1 ]]; then
        echo "ERROR: shell command requires exactly one service name." >&2
        usage >&2
        exit 1
    fi

    if ! is_valid_service "${service}"; then
        echo "ERROR: unknown service '${service}'." >&2
        usage >&2
        exit 1
    fi

    docker exec -it "${service}" /bin/bash
}

# 첫 번째 인자를 subcommand로 해석하고, 각 명령에 맞는 함수로 dispatch합니다.
main() {
    local command="${1:-}"

    case "${command}" in
        up)
            shift
            if [[ "$#" -ne 0 ]]; then
                echo "ERROR: up does not accept extra arguments." >&2
                usage >&2
                exit 1
            fi
            command_up
            ;;
        stop)
            shift
            if [[ "$#" -ne 0 ]]; then
                echo "ERROR: stop does not accept extra arguments." >&2
                usage >&2
                exit 1
            fi
            command_stop
            ;;
        down)
            shift
            if [[ "$#" -ne 0 ]]; then
                echo "ERROR: down does not accept extra arguments." >&2
                usage >&2
                exit 1
            fi
            command_down
            ;;
        logs)
            shift
            if [[ "$#" -ne 0 ]]; then
                echo "ERROR: logs does not accept extra arguments." >&2
                usage >&2
                exit 1
            fi
            command_logs
            ;;
        shell)
            shift
            command_shell "$@"
            ;;
        -h|--help|help)
            usage
            ;;
        "")
            usage >&2
            exit 1
            ;;
        *)
            echo "ERROR: unknown command '${command}'." >&2
            usage >&2
            exit 1
            ;;
    esac
}

main "$@"
