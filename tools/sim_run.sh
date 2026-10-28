#!/usr/bin/env bash

# 사용자 지정 월드·드론 모델로 simulation, ground, drone 컨테이너를 실행하는 스크립트입니다.
# CLI 인자와 리소스 파일을 검사하고, sim_build.sh로 만든 이미지를 실행해 xterm에서 tmux에 접속합니다.
# 원래 터미널에서 키를 누르거나 종료 신호를 받으면 이 프로젝트의 컨테이너를 제거합니다.
# 명령 실패, 미정의 변수 사용, 파이프라인 실패를 감지하면 실행을 중단합니다.
set -euo pipefail

# SCRIPT_DIR: BASH_SOURCE[0]의 부모를 절대 경로로 계산해 현재 작업 디렉터리와 무관하게 tools를 찾습니다.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# PROJECT_ROOT: SCRIPT_DIR의 상위 경로로, 호스트 workspace와 커스텀 리소스 경로를 조합할 때 사용합니다.
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# SERVICES: 생성·삭제 대상인 세 컨테이너 이름을 배열로 보관해 정리 범위를 제한합니다.
SERVICES=("simulation" "drone" "ground")
# CUDA_VERSION: sim_build.sh와 같은 버전 문자열을 사용해 실행할 이미지 태그를 구성합니다.
CUDA_VERSION="13.3.0"
# SIMULATION_IMAGE: CUDA_VERSION을 태그에 넣어 PX4 SITL·Gazebo 이미지의 로컬 이름을 구성합니다.
SIMULATION_IMAGE="dronesimenv/simulation:cuda${CUDA_VERSION}"
# DRONE_IMAGE: CUDA_VERSION을 태그에 넣어 ROS 2·DDS Agent 이미지의 로컬 이름을 구성합니다.
DRONE_IMAGE="dronesimenv/drone:cuda${CUDA_VERSION}"
# GROUND_IMAGE: CUDA_VERSION을 태그에 넣어 QGroundControl 이미지의 로컬 이름을 구성합니다.
GROUND_IMAGE="dronesimenv/ground:cuda${CUDA_VERSION}"
# CLEANUP_DONE: cleanup이 정리를 시작하면 true가 되어 종료 신호가 겹쳐도 중복 삭제를 막습니다.
CLEANUP_DONE=false
# CLEANUP_ENABLED: 사전 검사가 끝나 컨테이너 변경을 시작할 때만 true가 되어 조기 삭제를 막습니다.
CLEANUP_ENABLED=false
# WORLD_NAME: --world에서 받은 확장자 없는 이름으로, 월드 SDF 경로와 PX4 환경변수를 구성합니다.
WORLD_NAME=""
# MODEL_NAME: --model에서 받은 폴더 이름으로, 커스텀 모델 경로와 Gazebo 생성 모델 이름을 구성합니다.
MODEL_NAME=""
# AIRFRAME_ID: 모델 이름과 별개로 PX4 제어 파라미터를 선택하며 --airframe으로 덮어쓸 수 있습니다.
# 기본값 4001은 쿼드콥터 설정이므로 다른 기체는 구조·액추에이터 매핑에 맞는 ID를 지정해야 합니다.
AIRFRAME_ID="4001"
# WORLD_FILE: validate_resources가 찾은 호스트 SDF 절대 경로로, 컨테이너의 월드 파일에 직접 마운트합니다.
WORLD_FILE=""
# MODEL_DIR: 모델 루트와 MODEL_NAME을 조합한 호스트 경로로, 필수 모델 파일 두 개를 검사할 때 사용합니다.
MODEL_DIR=""

# usage: 인자 없이 호출하며 필수 리소스 인자, 검색 경로, 기체 설정 기본값을 표준 출력에 표시합니다.
usage() {
    cat <<EOF
Usage: $0 --world NAME --model NAME [--airframe ID]

World: simulation/simulation_ws/src/simulation_resources/worlds/NAME/NAME.sdf
       or simulation/simulation_ws/src/simulation_resources/worlds/NAME.sdf
Model: simulation/simulation_ws/src/simulation_resources/drone_models/NAME/model.sdf

Resources are loaded from these host paths, including when their names match built-in assets.
--airframe selects PX4 flight parameters independently of the model (default: 4001, quadrotor).
EOF
}

# parse_options: 전달받은 CLI 인자 배열을 순회하고 옵션·값 쌍을 전역 선택 변수에 저장합니다.
# 정상 입력은 0, 잘못된 옵션·누락 값은 1, 도움말 요청은 2를 반환해 main이 실행 여부를 결정합니다.
parse_options() {
    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            --world|--model|--airframe)
                # option: 현재 인자 $1을 보관해 값 검증 오류와 저장 대상 변수 선택에 같은 옵션명을 사용합니다.
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

# validate_resources: 전역 선택값의 이름 형식과 양수 airframe ID를 검사하고 호스트 리소스 경로를 확정합니다.
# <이름>/<이름>.sdf를 먼저, <이름>.sdf를 다음으로 찾으며 필수 파일이 없으면 1을 반환합니다.
validate_resources() {
    # resource_root: 저장소 루트에 고정 리소스 경로를 붙여 월드·모델의 공통 호스트 디렉터리를 만듭니다.
    local resource_root="${PROJECT_ROOT}/simulation/simulation_ws/src/simulation_resources"
    # worlds_root: resource_root 아래 worlds에서 폴더형 또는 단일 파일형 월드 SDF를 찾습니다.
    local worlds_root="${resource_root}/worlds"
    # models_root: resource_root 아래 drone_models에서 MODEL_NAME과 일치하는 모델 폴더를 찾습니다.
    local models_root="${resource_root}/drone_models"

    [[ "${WORLD_NAME}" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]] || {
        echo "ERROR: invalid world name: ${WORLD_NAME}" >&2
        return 1
    }
    [[ "${MODEL_NAME}" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]] || {
        echo "ERROR: invalid model name: ${MODEL_NAME}" >&2
        return 1
    }
    [[ "${AIRFRAME_ID}" =~ ^[1-9][0-9]*$ ]] || {
        echo "ERROR: --airframe must be a positive PX4 autostart ID." >&2
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

# is_wsl2: /proc/version의 microsoft 문자열을 대소문자 구분 없이 검색해 WSL용 실행 옵션 적용 여부를 반환합니다.
is_wsl2() {
    # 이 검사는 WSL 커널 표식을 사용하며 파일을 읽을 수 없거나 표식이 없으면 실패 상태를 반환합니다.
    grep -qi microsoft /proc/version 2>/dev/null
}

# require_docker: PATH의 Docker 명령과 docker info의 성공 여부를 확인하고 사용할 수 없으면 종료 코드 1로 끝냅니다.
require_docker() {
    # 실행 파일 존재 여부를 먼저 검사한 뒤 현재 사용자가 Docker 데몬에 접근 가능한지 확인합니다.
    command -v docker >/dev/null 2>&1 || {
        echo "ERROR: Docker is not installed or is not on PATH." >&2
        exit 1
    }

    docker info >/dev/null 2>&1 || {
        echo "ERROR: Docker is not ready for the current user." >&2
        exit 1
    }
}

# require_xterm: 호스트 PATH에서 xterm을 찾아 컨테이너별 터미널을 열 수 있는지 검사하고 없으면 종료합니다.
require_xterm() {
    # xterm은 Ubuntu 또는 WSL2 호스트에서 창을 여는 프로그램이므로 컨테이너 내부 설치로 대체되지 않습니다.
    command -v xterm >/dev/null 2>&1 || {
        echo "ERROR: xterm is not installed or is not on PATH." >&2
        echo "Install it on the host, then run this script again:" >&2
        echo "  sudo apt-get update && sudo apt-get install -y xterm" >&2
        exit 1
    }
}

# container_exists: $1의 정확한 컨테이너 이름을 Docker로 조회하고 존재하면 0, 조회 실패 시 비정상 상태를 반환합니다.
container_exists() {
    # 조회 결과와 오류 메시지는 숨기고 Docker의 종료 상태만 호출부의 조건문에 전달합니다.
    docker container inspect "$1" >/dev/null 2>&1
}

# require_images: 세 서비스 이미지의 로컬 존재 여부를 확인하고 하나라도 없으면 기존 컨테이너 변경 전에 종료합니다.
require_images() {
    # image: 세 이미지 이름을 순서대로 받아 docker image inspect에 전달하는 반복 변수입니다.
    local image

    for image in "${SIMULATION_IMAGE}" "${DRONE_IMAGE}" "${GROUND_IMAGE}"; do
        docker image inspect "${image}" >/dev/null 2>&1 || {
            echo "ERROR: image '${image}' was not found." >&2
            echo "Run '${SCRIPT_DIR}/sim_build.sh' before starting containers." >&2
            exit 1
        }
    done
}

# remove_project_containers: SERVICES의 이름을 정확히 조회해 기존 컨테이너가 있을 때 강제 종료·삭제합니다.
remove_project_containers() {
    # service: SERVICES의 현재 이름을 보관하며 존재 검사와 삭제 명령에 동일한 이름을 전달합니다.
    local service

    for service in "${SERVICES[@]}"; do
        if container_exists "${service}"; then
            # 이름 패턴 검색 대신 SERVICES에 명시된 컨테이너만 삭제합니다.
            echo "Removing ${service} container..."
            docker rm --force "${service}" >/dev/null
        fi
    done
}

# cleanup: EXIT 트랩의 종료 코드를 보존하고 활성화·중복 실행 플래그를 검사해 세 컨테이너를 정리합니다.
# 정리 중 발생한 개별 삭제 오류는 경고로 출력하고, 마지막에는 원래 종료 코드로 스크립트를 끝냅니다.
cleanup() {
    # exit_code: 함수 진입 직전의 $?를 즉시 저장해 정리 명령이 원래 실패 원인을 덮어쓰지 않도록 합니다.
    local exit_code="$?"
    # service: SERVICES를 순회하며 정리 대상 컨테이너의 존재 검사와 삭제에 사용할 이름을 보관합니다.
    local service

    # 컨테이너를 변경하기 전이라면 삭제 없이 원래 종료 코드로 끝냅니다.
    [[ "${CLEANUP_ENABLED}" == true ]] || exit "${exit_code}"

    # 정리 시작을 기록하고 트랩을 해제해 EXIT·종료 신호가 겹쳐도 다시 정리하지 않습니다.
    [[ "${CLEANUP_DONE}" == true ]] && exit "${exit_code}"
    CLEANUP_DONE=true
    trap - EXIT INT TERM

    echo
    echo "Stopping and removing DroneSimEnv containers..."
    for service in "${SERVICES[@]}"; do
        if container_exists "${service}"; then
            # --force로 실행 중인 컨테이너도 중지한 뒤 삭제하며 실패해도 나머지 대상을 계속 정리합니다.
            docker rm --force "${service}" >/dev/null 2>&1 || \
                echo "WARNING: Could not remove ${service}." >&2
        fi
    done
    echo "DroneSimEnv containers are down."
    exit "${exit_code}"
}

# configure_x11_access: 호스트 xhost로 로컬 Docker의 X11 접근을 허용하고 실패 시 GUI 관련 경고를 출력합니다.
configure_x11_access() {
    # xhost가 없거나 권한 설정에 실패해도 실행을 중단하지 않고 사용자가 원인을 볼 수 있게 알립니다.
    if command -v xhost >/dev/null 2>&1; then
        if ! xhost +local:docker >/dev/null 2>&1; then
            echo "WARNING: X11 access was not granted. GUI windows may not open." >&2
        fi
    else
        echo "WARNING: xhost is unavailable. GUI windows may not open." >&2
    fi
}

# run_service: $1 서비스 이름, $2 이미지, $3 호스트 소스, $4 컨테이너 소스 경로로 Docker 컨테이너를 생성합니다.
# 공통 실행 옵션에 simulation의 커스텀 리소스 연결과 WSLg 또는 X11 옵션을 추가해 백그라운드로 실행합니다.
run_service() {
    # service: $1에서 받은 이름으로 컨테이너를 식별하고 서비스별 옵션 적용 여부를 결정합니다.
    local service="$1"
    # image: $2에서 받은 빌드 이미지 이름을 docker run의 마지막 인자로 전달합니다.
    local image="$2"
    # workspace_source: $3의 호스트 src 경로를 bind mount 원본으로 사용합니다.
    local workspace_source="$3"
    # workspace_target: $4의 컨테이너 src 경로를 bind mount 대상으로 사용합니다.
    local workspace_target="$4"
    # run_args: Docker 옵션을 배열 원소로 보관해 공백이 있는 경로도 하나의 인자로 유지합니다.
    local -a run_args=(
        --detach
        --interactive
        --tty
        --name "${service}"
        --privileged
        # 호스트 네트워크와 IPC를 공유해 세 컨테이너 사이의 통신 경로를 맞춥니다.
        --network host
        --ipc host
        --gpus all
        # QT_X11_NO_MITSHM: Qt의 X11 공유 메모리 사용을 꺼 컨테이너의 화면 표시 충돌을 줄입니다.
        --env "QT_X11_NO_MITSHM=1"
        # NVIDIA_DRIVER_CAPABILITIES: NVIDIA 런타임이 그래픽·연산을 포함한 드라이버 기능을 노출하도록 합니다.
        --env "NVIDIA_DRIVER_CAPABILITIES=all"
        # NVIDIA_VISIBLE_DEVICES: NVIDIA 런타임에 모든 GPU의 노출을 요청합니다.
        --env "NVIDIA_VISIBLE_DEVICES=all"
        --volume "/tmp/.X11-unix:/tmp/.X11-unix:rw"
        # 호스트 src를 읽기·쓰기 마운트해 사용자 소스 변경이 컨테이너에 바로 보이도록 합니다.
        --volume "${workspace_source}:${workspace_target}:rw"
    )

    # simulation과 drone에는 추가 공유 메모리 공간을 지정합니다.
    if [[ "${service}" == "simulation" || "${service}" == "drone" ]]; then
        run_args+=(--shm-size 2g)
    fi

    if [[ "${service}" == "simulation" ]]; then
        # 커스텀 모델 루트를 PX4 모델 경로에 덮어 마운트해 내장 모델 파일을 가립니다.
        # 선택한 월드 파일도 직접 읽기 전용으로 연결해 이미지의 기존 파일과 섞이지 않도록 합니다.
        run_args+=(
            --volume "${PROJECT_ROOT}/simulation/simulation_ws/src/simulation_resources/drone_models:/DroneSimEnv/PX4-Autopilot/Tools/simulation/gz/models:ro"
            --volume "${WORLD_FILE}:/DroneSimEnv/PX4-Autopilot/Tools/simulation/gz/worlds/${WORLD_NAME}.sdf:ro"
        )
        # PX4에는 커스텀 리소스 이름과 기체 제어 설정을 독립적인 환경변수로 전달합니다.
        run_args+=(
            # PX4_GZ_WORLD: WORLD_NAME으로 연결한 SDF를 선택하고 Gazebo 월드 서비스 이름에 사용합니다.
            --env "PX4_GZ_WORLD=${WORLD_NAME}"
            # PX4_SIM_MODEL: PX4가 gz_ 접두사를 제거한 뒤 models/<MODEL_NAME>/model.sdf를 열도록 합니다.
            --env "PX4_SIM_MODEL=gz_${MODEL_NAME}"
            # PX4_SYS_AUTOSTART: AIRFRAME_ID로 제어 파라미터를 선택해 모델 이름 기반 내장 airframe 검색을 건너뜁니다.
            --env "PX4_SYS_AUTOSTART=${AIRFRAME_ID}"
            # PX4_SIMULATOR: PX4의 시뮬레이터 시작 스크립트가 Gazebo 연결 경로를 선택하도록 합니다.
            --env "PX4_SIMULATOR=gz"
            # GZ_IP: Gazebo Transport가 호스트 네트워크의 루프백 주소를 통신 주소로 사용하도록 지정합니다.
            --env "GZ_IP=127.0.0.1"
            # GZ_SIM_RESOURCE_PATH: 콜론으로 구분한 커스텀 월드·모델 경로에서 Gazebo가 URI 리소스를 찾도록 합니다.
            --env "GZ_SIM_RESOURCE_PATH=/DroneSimEnv/simulation_ws/src/simulation_resources/worlds:/DroneSimEnv/simulation_ws/src/simulation_resources/worlds/${WORLD_NAME}:/DroneSimEnv/simulation_ws/src/simulation_resources/drone_models"
        )
    fi

    if is_wsl2; then
        # WSLg의 소켓·라이브러리를 연결하고 그래픽·오디오 환경변수를 전달합니다.
        run_args+=(
            # DISPLAY: 호스트 값을 전달하며 없으면 WSLg의 기본 X11 디스플레이 :0을 사용합니다.
            --env "DISPLAY=${DISPLAY:-:0}"
            # WAYLAND_DISPLAY: 호스트 값을 전달하며 없으면 WSLg의 기본 Wayland 소켓 이름을 사용합니다.
            --env "WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-wayland-0}"
            # XDG_RUNTIME_DIR: Wayland 런타임 소켓 경로를 전달하며 없으면 WSLg의 기본 디렉터리를 사용합니다.
            --env "XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/mnt/wslg/runtime-dir}"
            # PULSE_SERVER: WSLg의 오디오 서버 주소를 전달하며 없으면 기본 PulseServer 소켓을 사용합니다.
            --env "PULSE_SERVER=${PULSE_SERVER:-unix:/mnt/wslg/PulseServer}"
            # LD_LIBRARY_PATH: 동적 링커가 /usr/lib/wsl/lib의 WSL 드라이버 라이브러리를 찾도록 합니다.
            --env "LD_LIBRARY_PATH=/usr/lib/wsl/lib"
            # MESA_D3D12_DEFAULT_ADAPTER_NAME: Mesa D3D12 드라이버가 NVIDIA 이름의 어댑터를 선택하도록 요청합니다.
            --env "MESA_D3D12_DEFAULT_ADAPTER_NAME=NVIDIA"
            # LIBGL_ALWAYS_SOFTWARE: 소프트웨어 렌더링 강제 옵션을 꺼 하드웨어 렌더링을 사용할 수 있게 합니다.
            --env "LIBGL_ALWAYS_SOFTWARE=0"
            # __GLX_VENDOR_LIBRARY_NAME: GLX 로더가 NVIDIA 공급자의 라이브러리를 선택하도록 지정합니다.
            --env "__GLX_VENDOR_LIBRARY_NAME=nvidia"
            --volume "/mnt/wslg:/mnt/wslg"
            --volume "/usr/lib/wsl:/usr/lib/wsl"
            --device "/dev/dxg:/dev/dxg"
        )
    else
        # DISPLAY: Ubuntu 호스트의 X11 주소를 그대로 전달하며 미정의 상태는 빈 문자열로 처리합니다.
        run_args+=(--env "DISPLAY=${DISPLAY:-}")
    fi

    echo "Creating and starting ${service}..."
    docker run "${run_args[@]}" "${image}" >/dev/null
}

# start_px4: simulation 컨테이너에 shell·px4 tmux 창을 만들고 PX4 실행 파일과 Enter 키를 전송합니다.
# PX4 창은 빌드된 rootfs에서 시작해 초기화 파일을 찾게 하고, 실행 출력은 tmux에 남깁니다.
start_px4() {
    docker exec simulation tmux new-session -d -s simulation -n shell \
        -c /DroneSimEnv/simulation_ws
    docker exec simulation tmux new-window -t simulation -n px4 \
        -c /DroneSimEnv/PX4-Autopilot/build/px4_sitl_default/rootfs
    docker exec simulation tmux send-keys -t simulation:px4 \
        /DroneSimEnv/PX4-Autopilot/build/px4_sitl_default/bin/px4 Enter
}

# open_terminal: $1 컨테이너, $2 창 제목, $3 작업 경로로 호스트 xterm을 비동기 실행합니다.
# xterm 안에서 docker exec로 tmux 세션에 접속하며 같은 이름의 세션이 없으면 새로 만듭니다.
open_terminal() {
    # service: $1을 docker exec 대상 컨테이너 이름과 tmux 세션 이름에 함께 사용합니다.
    local service="$1"
    # title: $2를 xterm의 -T 옵션으로 전달해 서비스별 창 제목을 표시합니다.
    local title="$2"
    # workdir: $3을 tmux -c에 전달해 새 세션을 만들 때 사용할 컨테이너 작업 경로를 지정합니다.
    local workdir="$3"

    # -A는 기존 세션에 접속하거나 새로 생성하며, 마지막 &는 원래 터미널의 입력 대기를 유지합니다.
    xterm -T "${title}" -e \
        docker exec -it "${service}" \
        tmux new-session -A -s "${service}" -c "${workdir}" &
}

# main: CLI 인자를 검사한 뒤 이미지·호스트 도구를 확인하고 컨테이너, PX4, 서비스 터미널을 순서대로 시작합니다.
# 마지막에 키 입력을 기다리며 입력 종료·오류·신호로 함수가 끝나면 EXIT 트랩이 컨테이너를 정리합니다.
main() {
    # 도움말을 뜻하는 반환 코드 2는 정상 종료로 바꿔 Docker 검사나 컨테이너 변경 없이 끝냅니다.
    parse_options "$@" || {
        [[ "$?" -eq 2 ]] && return 0
        return 1
    }
    validate_resources

    require_docker
    require_images
    require_xterm
    configure_x11_access

    # 사전 검사가 끝난 뒤 정리를 활성화하고 같은 이름의 기존 컨테이너를 제거해 새로 실행합니다.
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
    start_px4

    # 새 xterm이 접속하기 전에 3초 대기하며, 이 대기는 PX4·Gazebo의 준비 완료 검사는 아닙니다.
    sleep 3
    open_terminal "drone" "Drone (ROS 2)" \
        "/DroneSimEnv/drone_ws"
    open_terminal "simulation" "Simulation (PX4)" \
        "/DroneSimEnv/PX4-Autopilot/build/px4_sitl_default/rootfs"
    open_terminal "ground" "Ground (QGC)" \
        "/DroneSimEnv/ground_ws"

    echo "DroneSimEnv is running. Press any key in this window to stop it."
    # IFS를 이 read에서만 비워 공백 키도 입력으로 받고, 한 글자 입력·EOF 여부로 종료 시점을 결정합니다.
    # read의 기본 저장 변수 REPLY 값은 사용하지 않고 입력 성공 여부만 검사합니다.
    if ! IFS= read -r -n 1 -s; then
        echo "Input closed. Stopping containers."
    fi
}

# 정상 종료·키 입력·예상하지 못한 실패는 EXIT에서 정리합니다.
# Ctrl+C(SIGINT)와 SIGTERM은 각각 130·143으로 종료해 EXIT가 해당 코드를 보존하도록 합니다.
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

main "$@"
