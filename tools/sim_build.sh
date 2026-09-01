#!/usr/bin/env bash

# Build the shared images and the three service images used by the simulator.
# This file only builds images. It does not start containers.
set -euo pipefail

# Find the tools folder and the top folder of this project.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# Keep Dockerfiles in one place so this script uses their new folder.
DOCKERFILE_DIR="${SCRIPT_DIR}/docker"

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

require_dockerfile() {
    # Give a clear error when a Dockerfile was moved or is missing.
    local dockerfile="$1"

    [[ -f "${dockerfile}" ]] || {
        echo "ERROR: Dockerfile was not found: ${dockerfile}" >&2
        exit 1
    }
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
    require_dockerfile "${DRONE_DOCKERFILE}"
    require_dockerfile "${SIMULATION_DOCKERFILE}"
    require_dockerfile "${GROUND_DOCKERFILE}"
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
