#!/usr/bin/env bash 

# Exit immediately if an error occurs while running the script
set -euo pipefail 
 
# Default behavior keeps the original `down` cleanup unless `--keep` is provided.
KEEP_CONTAINERS=false

usage() {
    echo "Usage: $0 [--keep]"
    echo "  --keep    Stop containers instead of removing them on exit"
}

# Parse optional flags before starting the environment.
for arg in "$@"; do
    case "${arg}" in
        --keep)
            KEEP_CONTAINERS=true
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: ${arg}" >&2
            usage >&2
            exit 1
            ;;
    esac
done

echo "🚀 Starting DroneSimEnv (ubuntu)..."

# Alow X11 access for Docker containers
xhost +local:docker

# Specify the custom compose file name to use
COMPOSE_FILE="Dockerfile/docker-compose-ubuntu.yml"
# Prevent cleanup from running twice when both SIGINT and EXIT are triggered.
CLEANUP_DONE=false

cleanup() {
    if [[ "${CLEANUP_DONE}" == "true" ]]; then
        return
    fi
    CLEANUP_DONE=true

    # Keep containers when requested, otherwise remove them as before.
    echo ""
    if [[ "${KEEP_CONTAINERS}" == "true" ]]; then
        echo "🛑 Stopping the environment and keeping containers..."
        docker compose -f "${COMPOSE_FILE}" stop
    else
        echo "🛑 Shutting down the environment and removing containers cleanly..."
        docker compose -f "${COMPOSE_FILE}" down
    fi
}

###################################################################
# Clean up containers on Ctrl+C
###################################################################
trap cleanup EXIT SIGINT SIGTERM

###################################################################
# Start containers in detached mode (-d)
###################################################################
echo "📦 Building and starting containers..."
docker compose -f "${COMPOSE_FILE}" up --build -d

# Wait 3 seconds for containers to fully start
echo "⏳ Waiting for terminal access (3 seconds)..."
sleep 3

###################################################################
# Open 3 new terminal windows (Ubuntu gnome-terminal)
###################################################################
echo "🖥️ Opening terminals for Companion, Drone_sim, and Ground."

# Terminal 1: Companion
gnome-terminal --title="Companion (ROS2)" -- bash -c "echo '🧠 Companion container.'; docker exec -it companion /bin/bash"

# Terminal 2: Drone_sim
gnome-terminal --title="Drone Sim (PX4)" -- bash -c "echo '🚁 Drone_sim container.'; docker exec -it drone_sim /bin/bash"

# Terminal 3: Ground
gnome-terminal --title="Ground (QGC)" -- bash -c "echo '🛰️ Ground container.'; docker exec -it ground /bin/bash"

###################################################################
# Follow logs in the main terminal
###################################################################
if [[ "${KEEP_CONTAINERS}" == "true" ]]; then
    echo "📄 Displaying logs. (Press Ctrl + C here to stop containers and keep them)"
else
    echo "📄 Displaying logs. (Press Ctrl + C here to stop the environment)"
fi
echo "----------------------------------------------------------------------"
docker compose -f "${COMPOSE_FILE}" logs -f
