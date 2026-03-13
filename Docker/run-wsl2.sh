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

###################################################################
# Check WSL2 environment and auto-install required packages/fonts
###################################################################
if ! grep -qi "microsoft" /proc/version; then 
    echo "ERROR: This script is for WSL2 environment only." 
    exit 1 
fi 

# Check whether xfce4-terminal or Korean/emoji fonts are missing
if ! command -v xfce4-terminal &> /dev/null || ! dpkg -s fonts-noto-cjk &> /dev/null; then
    echo "⚠️ The terminal app (xfce4) or Korean/emoji fonts are not installed."
    echo "📦 Automatically installing required packages... (You may be prompted for your password)"
    
    sudo apt-get update
    sudo apt-get install -y xfce4-terminal dbus-x11 fonts-noto-cjk fonts-noto-color-emoji
    
    echo "🔄 Refreshing the font cache..."
    fc-cache -fv > /dev/null 2>&1
    
    echo "✅ The terminal and fonts have been installed successfully!"
    echo "----------------------------------------------------------------------"
fi

echo "🚀 Starting DroneSimEnv (wsl2)..."

# Specify the custom compose file name to use
COMPOSE_FILE="Dockerfile/docker-compose-wsl2.yml"
# Prevent cleanup from running twice when both SIGINT and EXIT are triggered.
CLEANUP_DONE=false

# Alow X11 access for Docker containers
xhost +local:docker > /dev/null 2>&1 || true

# Force system encoding to UTF-8 to prevent broken characters
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8

cleanup() {
    if [[ "${CLEANUP_DONE}" == "true" ]]; then
        return
    fi
    CLEANUP_DONE=true

    # Keep containers when requested, otherwise remove them as before.
    echo -e "\n"
    if [[ "${KEEP_CONTAINERS}" == "true" ]]; then
        echo "🛑 Stopping the environment and keeping containers..."
        docker compose -f "${COMPOSE_FILE}" stop
    else
        echo "🛑 Shutting down the environment and removing containers cleanly..."
        docker compose -f "${COMPOSE_FILE}" down
    fi
}

###################################################################
# 🛑 Clean up containers on Ctrl+C
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
# Open 3 xfce4-terminal windows
###################################################################
echo "🖥️ Opening 3 new windows using xfce4-terminal..."

# Terminal 1: Companion
env GTK_THEME=Adwaita:dark xfce4-terminal --title="Companion (ROS2)" -x bash -c "echo '🧠 Companion container.'; docker exec -it companion /bin/bash" &
# Terminal 2: Drone_sim
env GTK_THEME=Adwaita:dark xfce4-terminal --title="Drone Sim (PX4)" -x bash -c "echo '🚁 Drone_sim container.'; docker exec -it drone_sim /bin/bash" &
# Terminal 3: Ground
env GTK_THEME=Adwaita:dark xfce4-terminal --title="Ground (QGC)" -x bash -c "echo '🛰️ Ground container.'; docker exec -it ground /bin/bash" &

###################################################################
# Follow logs in the main terminal
###################################################################
echo "----------------------------------------------------------------------"
if [[ "${KEEP_CONTAINERS}" == "true" ]]; then
    echo "📄 Displaying logs. (Press Ctrl + C here to stop containers and keep them)"
else
    echo "📄 Displaying logs. (Press Ctrl + C here to stop the environment)"
fi
echo "----------------------------------------------------------------------"
docker compose -f "${COMPOSE_FILE}" logs -f
