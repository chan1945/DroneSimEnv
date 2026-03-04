#!/usr/bin/env bash 

# 스크립트 실행 중 에러 발생 시 즉시 종료 
set -euo pipefail 
 
echo "🚀 드론 시뮬레이션 환경을 시작합니다..."

# X11 권한 허용
xhost +local:docker

# 사용할 커스텀 compose 파일 이름 지정
COMPOSE_FILE="Dockerfile/docker-compose-ubuntu.yml"

# =================================================================
# 🛑 스크립트 종료 시(Ctrl+C) 컨테이너 삭제
# =================================================================
trap 'echo ""; echo "🛑 환경을 종료하고 컨테이너를 깨끗하게 삭제합니다..."; docker compose -f "${COMPOSE_FILE}" down' EXIT SIGINT

# =================================================================
# 1. 컨테이너를 백그라운드(-d)로 띄우기
# =================================================================
echo "📦 컨테이너를 빌드하고 실행합니다..."
docker compose -f "${COMPOSE_FILE}" up --build -d

# 컨테이너가 완전히 켜질 때까지 3초 대기
echo "⏳ 터미널 접속을 위해 3초 대기합니다..."
sleep 3

# =================================================================
# 2. 새로운 터미널 창 2개 띄우기 (우분투 gnome-terminal)
# =================================================================
echo "🖥️ Companion(ROS 2) 및 Drone_sim(PX4) 터미널을 엽니다."

# 터미널 1: Companion (ROS 2) 접속
gnome-terminal --title="Companion (ROS2)" -- bash -c "echo '🧠 Companion 컨테이너(ROS 2)에 접속했습니다.'; docker exec -it companion /bin/bash"

# 터미널 2: Drone_sim (PX4) 접속
gnome-terminal --title="Drone Sim (PX4)" -- bash -c "echo '🚁 Drone_sim 컨테이너(PX4)에 접속했습니다.'; docker exec -it drone_sim /bin/bash"

# =================================================================
# 3. 메인 화면은 기존처럼 통합 로그 출력
# =================================================================
echo "📄 전체 로그를 출력합니다. (환경을 종료하려면 여기서 Ctrl + C 를 누르세요)"
echo "----------------------------------------------------------------------"
docker compose -f "${COMPOSE_FILE}" logs -f