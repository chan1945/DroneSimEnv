#!/usr/bin/env bash

# Build the shared images and the three service images used by the simulator.
# This file only builds images. It does not start containers.
set -euo pipefail

# Find the tools folder and the top folder of this project.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# Keep Dockerfiles in one place so this script uses their new folder.
DOCKERFILE_DIR="${SCRIPT_DIR}/docker"
# Keep downloaded Git sources outside the service workspaces.
GIT_CLONE_DIR="${SCRIPT_DIR}/_git_clones"

# Keep the CUDA version in every tag so related images are easy to identify.
CUDA_VERSION="13.3.0"
BASE_IMAGE="dronesimenv/base_amd64:cuda${CUDA_VERSION}"
ROS2_HUMBLE_IMAGE="dronesimenv/ros2_humble:cuda${CUDA_VERSION}-humble"
SIMULATION_IMAGE="dronesimenv/simulation:cuda${CUDA_VERSION}"
DRONE_IMAGE="dronesimenv/drone:cuda${CUDA_VERSION}"
GROUND_IMAGE="dronesimenv/ground:cuda${CUDA_VERSION}"
DRONE_DOCKERFILE="${DOCKERFILE_DIR}/Dockerfile.drone"
SIMULATION_DOCKERFILE="${DOCKERFILE_DIR}/Dockerfile.simulation"
GROUND_DOCKERFILE="${DOCKERFILE_DIR}/Dockerfile.ground"

# Each item is: Git URL;required ref;folder name inside _git_clones.
REPOS=(
    # simulation image
    "https://github.com/PX4/PX4-Autopilot.git;v1.16.2;PX4-Autopilot"

    # ground image
    # The ground image does not need an external Git source yet.

    # drone image
    "https://github.com/PX4/px4_msgs.git;release/1.16;px4_msgs"
    "https://github.com/eProsima/Micro-XRCE-DDS-Agent.git;v2.4.3;Micro-XRCE-DDS-Agent"
)

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

require_git() {
    # Git runs on the host before Docker receives the cached source files.
    command -v git >/dev/null 2>&1 || {
        echo "ERROR: Git is not installed or is not on PATH." >&2
        exit 1
    }
}

require_dockerfile() {
    # Give a clear error when a Dockerfile was moved or is missing.
    local dockerfile="$1"

    [[ -f "${dockerfile}" ]] || {
        echo "ERROR: Dockerfile was not found: ${dockerfile}" >&2
        exit 1
    }
}

normalise_git_url() {
    # Ignore a final slash and .git so equivalent Git URLs compare correctly.
    local url="$1"

    url="${url%/}"
    url="${url%.git}"
    printf '%s\n' "${url}"
}

validate_existing_repo() {
    # Refuse unknown folders instead of deleting files that may be important.
    local repo_path="$1"
    local expected_url="$2"
    local actual_root
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

checkout_requested_ref() {
    # Reuse a local ref when possible. Download only if this clone lacks it.
    local repo_path="$1"
    local ref="$2"
    local requested_commit
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

    # A detached checkout makes the Docker source match the requested ref exactly.
    requested_commit="$(git -C "${repo_path}" rev-parse --verify "${ref}^{commit}")"
    git -C "${repo_path}" checkout --quiet --detach "${requested_commit}"
}

prepare_repo() {
    # Create one managed cache folder, then clone or verify one requested source.
    local repo_url="$1"
    local repo_ref="$2"
    local repo_name="$3"
    local repo_path="${GIT_CLONE_DIR}/${repo_name}"

    if [[ -e "${repo_path}" || -L "${repo_path}" ]]; then
        validate_existing_repo "${repo_path}" "${repo_url}"
        echo "Using cached ${repo_name} source."
    else
        echo "Cloning ${repo_name} source..."
        if [[ "${repo_name}" == "PX4-Autopilot" ]]; then
            # PX4 cannot build without the Git submodules included in this clone.
            git clone --recursive --branch "${repo_ref}" "${repo_url}" "${repo_path}"
        else
            git clone --branch "${repo_ref}" "${repo_url}" "${repo_path}"
        fi
    fi

    checkout_requested_ref "${repo_path}" "${repo_ref}"

    if [[ "${repo_name}" == "PX4-Autopilot" ]]; then
        # This initializes missing PX4 submodules without changing pinned commits.
        git -C "${repo_path}" submodule sync --recursive
        git -C "${repo_path}" submodule update --init --recursive
    fi
}

prepare_git_sources() {
    # Make the cache before Docker builds so Dockerfiles can COPY its sources.
    local repo
    local repo_url
    local repo_ref
    local repo_name

    mkdir -p "${GIT_CLONE_DIR}"

    for repo in "${REPOS[@]}"; do
        IFS=';' read -r repo_url repo_ref repo_name <<< "${repo}"
        [[ -n "${repo_url}" && -n "${repo_ref}" && -n "${repo_name}" ]] || {
            echo "ERROR: invalid Git repository setting: ${repo}" >&2
            exit 1
        }
        prepare_repo "${repo_url}" "${repo_ref}" "${repo_name}"
    done
}

build_image() {
    local name="$1"
    local image="$2"
    local dockerfile="$3"
    local target="${4:-}"
    shift 4

    local -a build_args=(
        --tag "${image}"
        --file "${dockerfile}"
    )

    # A target lets one Dockerfile create more than one reusable image.
    if [[ -n "${target}" ]]; then
        build_args+=(--target "${target}")
    fi

    # Extra arguments choose the already-built shared ROS image when needed.
    build_args+=("$@")

    # Use the project folder as the build context, just like Compose did.
    echo "Building ${name} image..."
    docker build "${build_args[@]}" "${PROJECT_ROOT}"
}

main() {
    # Only --help is accepted because every image is always built together.
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
    # Build the common layers first. The service images reuse these layers.
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
