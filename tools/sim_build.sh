#!/usr/bin/env bash

# 외부 Git 소스를 준비하고 공통 CUDA·ROS 2 이미지와 drone·simulation·ground 이미지를 빌드하는 스크립트입니다.
# 기존 소스 캐시의 원격 주소·변경 여부를 검사하고 지정된 Git 참조로 맞춘 뒤 의존 순서대로 Docker를 호출합니다.
# 명령 실패, 미정의 변수 사용, 파이프라인 실패를 감지하면 이후 빌드를 중단합니다.
set -euo pipefail

# SCRIPT_DIR: BASH_SOURCE[0]의 부모를 절대 경로로 계산해 실행 위치와 무관하게 tools 디렉터리를 찾습니다.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# PROJECT_ROOT: SCRIPT_DIR의 상위 절대 경로로, Docker 빌드 컨텍스트와 저장소 내 경로의 기준입니다.
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# DOCKERFILE_DIR: SCRIPT_DIR에 docker를 붙여 각 이미지의 Dockerfile 검색 경로를 구성합니다.
DOCKERFILE_DIR="${SCRIPT_DIR}/docker"
# GIT_CLONE_DIR: tools/_git_clones에 외부 저장소를 캐시해 서비스 workspace와 분리하고 다음 빌드에서 재사용합니다.
GIT_CLONE_DIR="${SCRIPT_DIR}/_git_clones"

# CUDA_VERSION: 공통·서비스 이미지 태그에 동일하게 넣을 CUDA 버전이며 sim_run.sh의 값과 맞춰야 합니다.
CUDA_VERSION="13.3.0"
# BASE_IMAGE: CUDA_VERSION을 태그로 사용하는 공통 도구 이미지 이름이며 base_amd64 타깃을 빌드해 생성합니다.
BASE_IMAGE="dronesimenv/base_amd64:cuda${CUDA_VERSION}"
# ROS2_HUMBLE_IMAGE: CUDA·Humble 버전을 태그에 넣은 공통 ROS 2 이미지이며 서비스 빌드 인자로도 전달합니다.
ROS2_HUMBLE_IMAGE="dronesimenv/ros2_humble:cuda${CUDA_VERSION}-humble"
# SIMULATION_IMAGE: 공통 ROS 2 이미지에 PX4·Gazebo를 추가한 결과를 저장할 서비스 이미지 태그입니다.
SIMULATION_IMAGE="dronesimenv/simulation:cuda${CUDA_VERSION}"
# DRONE_IMAGE: 공통 ROS 2 이미지에 DDS Agent·Gazebo 브리지·workspace를 추가한 결과의 이미지 태그입니다.
DRONE_IMAGE="dronesimenv/drone:cuda${CUDA_VERSION}"
# GROUND_IMAGE: 공통 ROS 2 이미지에 QGroundControl·workspace를 추가한 결과를 저장할 이미지 태그입니다.
GROUND_IMAGE="dronesimenv/ground:cuda${CUDA_VERSION}"
# DRONE_DOCKERFILE: 공통 두 타깃과 drone 타깃을 정의한 파일의 절대 경로로, 사전 검사와 빌드에 사용합니다.
DRONE_DOCKERFILE="${DOCKERFILE_DIR}/Dockerfile.drone"
# SIMULATION_DOCKERFILE: simulation 이미지 정의의 절대 경로로, 파일 존재 검사 후 docker build에 전달합니다.
SIMULATION_DOCKERFILE="${DOCKERFILE_DIR}/Dockerfile.simulation"
# GROUND_DOCKERFILE: ground 이미지 정의의 절대 경로로, 파일 존재 검사 후 docker build에 전달합니다.
GROUND_DOCKERFILE="${DOCKERFILE_DIR}/Dockerfile.ground"

# REPOS: 외부 소스별 Git URL·요청 참조·캐시 폴더명을 세미콜론으로 연결한 문자열 배열입니다.
# prepare_git_sources가 각 항목을 세 필드로 나누고 prepare_repo에 전달합니다.
REPOS=(
    # simulation: PX4 v1.16.2와 해당 커밋에 고정된 하위 모듈을 준비합니다.
    "https://github.com/PX4/PX4-Autopilot.git;v1.16.2;PX4-Autopilot"

    # ground: QGC AppImage를 Dockerfile에서 받으므로 여기서 준비할 Git 저장소는 없습니다.

    # drone: PX4 1.16 계열 메시지 정의와 DDS Agent v2.4.3 소스를 준비합니다.
    "https://github.com/PX4/px4_msgs.git;release/1.16;px4_msgs"
    "https://github.com/eProsima/Micro-XRCE-DDS-Agent.git;v2.4.3;Micro-XRCE-DDS-Agent"
)

# usage: 인자 없이 호출하며 사용법, 이미지 빌드 순서, 외부 소스 캐시 경로를 표준 출력에 표시합니다.
usage() {
    cat <<EOF
Usage:
  $0
  $0 --help

Builds these images in dependency order:
  ${BASE_IMAGE}
  ${ROS2_HUMBLE_IMAGE}
  ${DRONE_IMAGE}
  ${SIMULATION_IMAGE}
  ${GROUND_IMAGE}

Before building, this script prepares Git sources in:
  ${GIT_CLONE_DIR}
EOF
}

# require_docker: PATH의 Docker 명령과 docker info를 검사하고 데몬 접근이 불가능하면 종료 코드 1로 끝냅니다.
require_docker() {
    # 실행 파일 존재 여부를 먼저 확인하고 현재 사용자의 Docker 데몬 접근 가능 여부를 검사합니다.
    command -v docker >/dev/null 2>&1 || {
        echo "ERROR: Docker is not installed or is not on PATH." >&2
        exit 1
    }

    docker info >/dev/null 2>&1 || {
        echo "ERROR: Docker is not ready for the current user." >&2
        exit 1
    }
}

# require_git: 외부 소스 준비에 사용할 호스트 Git을 PATH에서 찾고 없으면 오류 메시지와 함께 종료합니다.
require_git() {
    # 캐시 검증·복제는 Docker 빌드 전에 호스트에서 수행하므로 컨테이너의 Git으로 대체되지 않습니다.
    command -v git >/dev/null 2>&1 || {
        echo "ERROR: Git is not installed or is not on PATH." >&2
        exit 1
    }
}

# require_dockerfile: $1 경로가 일반 파일인지 검사해 잘못된 Dockerfile 경로로 빌드를 시작하지 않도록 합니다.
require_dockerfile() {
    # dockerfile: $1에서 받은 검사 대상 경로를 보관해 파일 존재 검사와 오류 메시지에 사용합니다.
    local dockerfile="$1"

    [[ -f "${dockerfile}" ]] || {
        echo "ERROR: Dockerfile was not found: ${dockerfile}" >&2
        exit 1
    }
}

# normalise_git_url: $1 URL 끝의 슬래시와 .git을 차례로 제거하고 비교용 문자열을 표준 출력에 반환합니다.
normalise_git_url() {
    # url: 입력 URL을 지역 변수로 복사해 접미사를 제거하되 원래 호출부의 값은 바꾸지 않습니다.
    local url="$1"

    url="${url%/}"
    url="${url%.git}"
    printf '%s\n' "${url}"
}

# validate_existing_repo: $1 캐시 경로의 Git 루트와 origin을 $2 예상 URL과 비교해 관리 대상 저장소인지 확인합니다.
# 심볼릭 링크·다른 저장소 내부 경로·잘못된 origin은 오류로 종료해 알 수 없는 디렉터리를 변경하지 않습니다.
validate_existing_repo() {
    # repo_path: $1에서 받은 캐시 경로로, 디렉터리 유형과 Git 루트·origin 조회의 작업 위치로 사용합니다.
    local repo_path="$1"
    # expected_url: $2의 예상 Git URL을 보관하고 정규화한 뒤 실제 origin과 비교합니다.
    local expected_url="$2"
    # actual_root: git rev-parse로 조회한 저장소 최상위 경로를 저장해 repo_path 자체가 루트인지 확인합니다.
    local actual_root
    # actual_url: git config로 읽은 origin 주소를 저장해 비어 있지 않은지와 예상 저장소 일치 여부를 검사합니다.
    local actual_url

    [[ -d "${repo_path}" && ! -L "${repo_path}" ]] || {
        echo "ERROR: cached repository is not a normal directory: ${repo_path}" >&2
        exit 1
    }

    git -C "${repo_path}" rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
        echo "ERROR: cached folder is not a Git repository: ${repo_path}" >&2
        exit 1
    }

    actual_root="$(git -C "${repo_path}" rev-parse --show-toplevel)"
    [[ "${actual_root}" == "$(cd "${repo_path}" && pwd -P)" ]] || {
        echo "ERROR: cached repository has an unexpected Git root: ${repo_path}" >&2
        exit 1
    }

    actual_url="$(git -C "${repo_path}" config --get remote.origin.url || true)"
    [[ -n "${actual_url}" ]] || {
        echo "ERROR: cached repository has no origin remote: ${repo_path}" >&2
        exit 1
    }

    [[ "$(normalise_git_url "${actual_url}")" == "$(normalise_git_url "${expected_url}")" ]] || {
        echo "ERROR: cached repository origin does not match: ${repo_path}" >&2
        exit 1
    }
}

# checkout_requested_ref: $1 저장소에서 $2 참조를 찾고 없으면 원격 참조·태그를 받아 커밋을 확정합니다.
# 로컬 변경이 있으면 종료하고, 변경이 없는 저장소만 요청 커밋으로 detached checkout합니다.
checkout_requested_ref() {
    # repo_path: $1의 저장소 경로를 Git 참조 조회·변경 검사·checkout의 작업 위치로 사용합니다.
    local repo_path="$1"
    # ref: $2의 태그·브랜치·커밋 표현식을 보관해 ^{commit}으로 해석 가능한지 검사합니다.
    local ref="$2"
    # requested_commit: ref를 실제 커밋 해시로 해석한 결과를 저장해 checkout 대상을 고정합니다.
    local requested_commit
    # repo_status: git status --porcelain 출력으로 추적·미추적 변경을 확인하고 덮어쓰기 가능성을 차단합니다.
    local repo_status

    if ! git -C "${repo_path}" rev-parse --verify --quiet "${ref}^{commit}" >/dev/null; then
        echo "Downloading ${ref} for $(basename "${repo_path}")..."
        git -C "${repo_path}" fetch --quiet --tags origin
    fi

    repo_status="$(git -C "${repo_path}" status --porcelain --untracked-files=normal)"
    [[ -z "${repo_status}" ]] || {
        echo "ERROR: cached repository has local changes: ${repo_path}" >&2
        exit 1
    }

    # 브랜치를 이동시키지 않는 detached checkout으로 빌드 소스를 확인된 커밋에 맞춥니다.
    requested_commit="$(git -C "${repo_path}" rev-parse --verify "${ref}^{commit}")"
    git -C "${repo_path}" checkout --quiet --detach "${requested_commit}"
}

# prepare_repo: $1 URL, $2 참조, $3 캐시 폴더명으로 외부 저장소를 재사용하거나 새로 복제합니다.
# 저장소를 요청 커밋으로 맞추고 PX4에 대해서는 해당 커밋의 하위 모듈까지 재귀적으로 초기화합니다.
prepare_repo() {
    # repo_url: $1의 원격 URL을 기존 캐시 검증 또는 새 git clone의 원본으로 사용합니다.
    local repo_url="$1"
    # repo_ref: $2의 요청 참조를 clone과 checkout에 전달해 원하는 버전의 소스를 준비합니다.
    local repo_ref="$2"
    # repo_name: $3의 캐시 폴더명을 보관하며 PX4 전용 하위 모듈 처리 여부도 이 값으로 구분합니다.
    local repo_name="$3"
    # repo_path: GIT_CLONE_DIR와 repo_name을 연결해 검사·복제·checkout에 사용할 절대 경로를 구성합니다.
    local repo_path="${GIT_CLONE_DIR}/${repo_name}"

    if [[ -e "${repo_path}" || -L "${repo_path}" ]]; then
        validate_existing_repo "${repo_path}" "${repo_url}"
        echo "Using cached ${repo_name} source."
    else
        echo "Cloning ${repo_name} source..."
        if [[ "${repo_name}" == "PX4-Autopilot" ]]; then
            # PX4는 하위 모듈 소스가 필요하므로 최초 복제부터 --recursive를 사용합니다.
            git clone --recursive --branch "${repo_ref}" "${repo_url}" "${repo_path}"
        else
            git clone --branch "${repo_ref}" "${repo_url}" "${repo_path}"
        fi
    fi

    checkout_requested_ref "${repo_path}" "${repo_ref}"

    if [[ "${repo_name}" == "PX4-Autopilot" ]]; then
        # 하위 모듈 URL을 동기화하고 상위 커밋이 지정한 버전으로 누락된 하위 모듈을 준비합니다.
        git -C "${repo_path}" submodule sync --recursive
        git -C "${repo_path}" submodule update --init --recursive
    fi
}

# prepare_git_sources: 캐시 루트를 만든 뒤 REPOS를 순회하며 각 항목을 파싱하고 prepare_repo로 준비합니다.
# 필수 세 필드가 비어 있으면 Dockerfile이 소스를 복사하기 전에 설정 오류로 종료합니다.
prepare_git_sources() {
    # repo: REPOS에서 읽은 세미콜론 구분 문자열 한 개를 보관해 read에 전달합니다.
    local repo
    # repo_url: IFS=';' read가 분리한 첫 번째 필드이며 외부 저장소의 원격 URL입니다.
    local repo_url
    # repo_ref: read가 분리한 두 번째 필드이며 준비할 Git 태그·브랜치·커밋 참조입니다.
    local repo_ref
    # repo_name: read가 분리한 세 번째 필드이며 GIT_CLONE_DIR 아래 캐시 폴더 이름입니다.
    local repo_name

    mkdir -p "${GIT_CLONE_DIR}"

    for repo in "${REPOS[@]}"; do
        # IFS: 이 read 명령에서만 구분자를 세미콜론으로 설정해 URL·참조·폴더명을 세 지역 변수에 나눠 저장합니다.
        IFS=';' read -r repo_url repo_ref repo_name <<< "${repo}"
        [[ -n "${repo_url}" && -n "${repo_ref}" && -n "${repo_name}" ]] || {
            echo "ERROR: invalid Git repository setting: ${repo}" >&2
            exit 1
        }
        prepare_repo "${repo_url}" "${repo_ref}" "${repo_name}"
    done
}

# build_image: $1 표시명, $2 이미지 태그, $3 Dockerfile, $4 선택적 타깃과 이후 추가 옵션으로 이미지를 빌드합니다.
# Docker 옵션을 배열로 구성하고 PROJECT_ROOT를 컨텍스트로 전달해 공백이 있는 경로도 보존합니다.
build_image() {
    # name: $1의 설명용 이름을 보관해 현재 빌드하는 이미지를 터미널에 표시합니다.
    local name="$1"
    # image: $2의 이미지 이름·태그를 docker build --tag에 전달합니다.
    local image="$2"
    # dockerfile: $3의 파일 경로를 docker build --file에 전달해 사용할 이미지 정의를 선택합니다.
    local dockerfile="$3"
    # target: $4의 멀티 스테이지 타깃 이름이며 빈 값이면 Dockerfile의 최종 스테이지를 빌드합니다.
    local target="${4:-}"
    shift 4

    # build_args: 태그·Dockerfile·타깃·추가 옵션을 배열로 모아 각 인자의 경계를 유지합니다.
    local -a build_args=(
        --tag "${image}"
        --file "${dockerfile}"
    )

    # target이 있을 때만 --target을 추가해 하나의 Dockerfile에서 공통·서비스 이미지를 선택합니다.
    if [[ -n "${target}" ]]; then
        build_args+=(--target "${target}")
    fi

    # 앞의 네 인자를 제거한 뒤 남은 옵션을 추가해 공통 ROS 이미지 같은 빌드 인자를 전달합니다.
    build_args+=("$@")

    # 저장소 루트를 빌드 컨텍스트로 사용해 Dockerfile의 상대 COPY 경로를 해석합니다.
    echo "Building ${name} image..."
    docker build "${build_args[@]}" "${PROJECT_ROOT}"
}

# main: 첫 인자로 도움말·잘못된 옵션을 구분하고 도구·파일 검사, 소스 준비, 이미지 빌드를 순서대로 수행합니다.
# 공통 base_amd64와 ros2_humble을 먼저 만든 뒤 이를 바탕으로 drone, simulation, ground를 빌드합니다.
main() {
    # 기본 동작은 전체 빌드이며 첫 인자가 도움말 옵션이면 준비 작업 없이 사용법만 출력합니다.
    case "${1:-}" in
        "") ;;
        -h|--help|help)
            usage
            return
            ;;
        *)
            echo "ERROR: unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
    esac

    require_docker
    require_git
    require_dockerfile "${DRONE_DOCKERFILE}"
    require_dockerfile "${SIMULATION_DOCKERFILE}"
    require_dockerfile "${GROUND_DOCKERFILE}"
    prepare_git_sources
    # 공통 이미지를 먼저 만들어 각 서비스의 FROM과 ROS2_HUMBLE_IMAGE 빌드 인자에서 재사용합니다.
    build_image "base_amd64" "${BASE_IMAGE}" "${DRONE_DOCKERFILE}" "base_amd64"
    build_image "ros2_humble" "${ROS2_HUMBLE_IMAGE}" "${DRONE_DOCKERFILE}" "ros2_humble"
    build_image "drone" "${DRONE_IMAGE}" "${DRONE_DOCKERFILE}" "drone" \
        --build-arg "ROS2_HUMBLE_IMAGE=${ROS2_HUMBLE_IMAGE}"
    build_image "simulation" "${SIMULATION_IMAGE}" \
        "${SIMULATION_DOCKERFILE}" "" \
        --build-arg "ROS2_HUMBLE_IMAGE=${ROS2_HUMBLE_IMAGE}"
    build_image "ground" "${GROUND_IMAGE}" \
        "${GROUND_DOCKERFILE}" "" \
        --build-arg "ROS2_HUMBLE_IMAGE=${ROS2_HUMBLE_IMAGE}"
    echo "All DroneSimEnv images are ready."
}

main "$@"
