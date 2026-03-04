#!/usr/bin/env bash 

# 스크립트 실행 중 에러 발생 시 즉시 종료 
set -euo pipefail 

# WSL2 환경 체크
if ! grep -qi "microsoft" /proc/version; then 
    echo "ERROR: 이 스크립트는 WSL2 환경 전용입니다." 
    exit 1 
fi 

echo "🚀 드론 시뮬레이션 환경을 시작합니다..."

# 사용할 커스텀 compose 파일 이름 지정
COMPOSE_FILE="Dockerfile/docker-compose-wsl2.yml"

# =================================================================
# 🛑 스크립트 종료 시(Ctrl+C) 컨테이너 삭제
# (EXIT 하나만 설정해도 SIGINT 발생 시 스크립트가 종료되면서 작동함)
# =================================================================
trap 'echo -e "\n🛑 환경을 종료하고 컨테이너를 깨끗하게 삭제합니다..."; docker compose -f "${COMPOSE_FILE}" down' EXIT

# =================================================================
# 1. 컨테이너를 백그라운드(-d)로 띄우기
# =================================================================
echo "📦 컨테이너를 빌드하고 실행합니다..."
docker compose -f "${COMPOSE_FILE}" up --build -d

# 컨테이너가 완전히 켜질 때까지 3초 대기
echo "⏳ 터미널 접속을 위해 3초 대기합니다..."
sleep 3

# =================================================================
# 2. 새로운 터미널 탭 2개 띄우기 (Windows Terminal 활용)
# =================================================================
echo "🖥️ Companion(ROS 2) 및 Drone_sim(PX4) 터미널을 새 탭으로 엽니다."

# 터미널 1: Companion (ROS 2) 접속 (새 탭)
wt.exe -w 0 new-tab --title "Companion (ROS2)" wsl.exe -e bash -c "echo '🧠 Companion 컨테이너(ROS 2)에 접속했습니다.'; docker exec -it companion /bin/bash; exec bash"

# 터미널 2: Drone_sim (PX4) 접속 (새 탭)
wt.exe -w 0 new-tab --title "Drone Sim (PX4)" wsl.exe -e bash -c "echo '🚁 Drone_sim 컨테이너(PX4)에 접속했습니다.'; docker exec -it drone_sim /bin/bash; exec bash"

# =================================================================
# 3. 메인 화면은 기존처럼 통합 로그 출력
# =================================================================
echo "----------------------------------------------------------------------"
echo "📄 전체 로그를 출력합니다. (환경을 종료하려면 여기서 Ctrl + C 를 누르세요)"
echo "----------------------------------------------------------------------"
docker compose -f "${COMPOSE_FILE}" logs -f