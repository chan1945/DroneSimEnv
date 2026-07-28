#!/usr/bin/env bash

# Build the three Docker images used by the simulator.
# This file only builds images. It does not start containers.
set -euo pipefail

# Find the scripts folder and the top folder of this project.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# These are the names Docker gives to the finished images.
SIMULATION_IMAGE="dronesimenv/simulation:latest"
DRONE_IMAGE="dronesimenv/drone:latest"
GROUND_IMAGE="dronesimenv/ground:latest"

usage() {
    cat <<EOF
Usage:
  $0
  $0 --help

Builds these images:
  ${SIMULATION_IMAGE}
  ${DRONE_IMAGE}
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

build_image() {
    local name="$1"
    local image="$2"
    local dockerfile="$3"

    # Use the project folder as the build context, just like Compose did.
    echo "Building ${name} image..."
    docker build \
        --tag "${image}" \
        --file "${PROJECT_ROOT}/Docker/Dockerfile/${dockerfile}" \
        "${PROJECT_ROOT}"
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
    build_image "simulation" "${SIMULATION_IMAGE}" "Dockerfile.simulation"
    build_image "drone" "${DRONE_IMAGE}" "Dockerfile.drone"
    build_image "ground" "${GROUND_IMAGE}" "Dockerfile.ground"
    echo "All DroneSimEnv images are ready."
}

main "$@"
