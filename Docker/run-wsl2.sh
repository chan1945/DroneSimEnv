#!/usr/bin/env bash 

# 스크립트 실행 중 에러 발생 시 즉시 종료 
set -euo pipefail 

# =================================================================
# 0. WSL2 환경 체크 및 필수 패키지/폰트 자동 설치
# =================================================================
if ! grep -qi "microsoft" /proc/version; then 
    echo "ERROR: 이 스크립트는 WSL2 환경 전용입니다." 
    exit 1 
fi 

# xfce4-terminal 또는 한글/이모지 폰트가 없는지 검사
if ! command -v xfce4-terminal &> /dev/null || ! dpkg -s fonts-noto-cjk &> /dev/null; then
    echo "⚠️ 터미널 앱(xfce4) 또는 한글/이모지 폰트가 설치되어 있지 않습니다."
    echo "📦 자동 설치를 진행합니다. (비밀번호 입력이 필요할 수 있습니다)"
    
    sudo apt-get update
    sudo apt-get install -y xfce4-terminal dbus-x11 fonts-noto-cjk fonts-noto-color-emoji
    
    echo "🔄 폰트 캐시를 갱신합니다..."
    fc-cache -fv > /dev/null 2>&1
    
    echo "✅ 터미널 및 폰트 설치가 완료되었습니다!"
    echo "----------------------------------------------------------------------"
fi

echo "🚀 드론 시뮬레이션 환경을 시작합니다..."

# 사용할 커스텀 compose 파일 이름 지정
COMPOSE_FILE="Dockerfile/docker-compose-wsl2.yml"

# X11 권한 허용
xhost +local:docker > /dev/null 2>&1 || true

# 글자 깨짐 방지를 위해 시스템 인코딩을 강제로 UTF-8로 설정
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8

# =================================================================
# 🛑 스크립트 종료 시(Ctrl+C) 컨테이너 삭제
# =================================================================
trap 'echo -e "\n🛑 환경을 종료하고 컨테이너를 깨끗하게 삭제합니다..."; docker compose -f "${COMPOSE_FILE}" down' EXIT SIGINT

# =================================================================
# 1. 컨테이너를 백그라운드(-d)로 띄우기
# =================================================================
echo "📦 컨테이너를 빌드하고 실행합니다..."
docker compose -f "${COMPOSE_FILE}" up --build -d

# 컨테이너가 완전히 켜질 때까지 대기
echo "⏳ 터미널 접속을 위해 3초 대기합니다..."
sleep 3

# =================================================================
# 2. xfce4-terminal 창 2개 띄우기 (다크 테마 완벽 적용)
# =================================================================
echo "🖥️ xfce4-terminal을 사용하여 새 창 2개를 엽니다..."

# xfce4-terminal은 다크 테마 적용이 매우 잘 먹힙니다. (-x 옵션으로 내부 명령어 실행)
env GTK_THEME=Adwaita:dark xfce4-terminal --title="Companion (ROS2)" -x bash -c "echo '🧠 Companion 컨테이너(ROS 2)에 접속 중...'; docker exec -it companion /bin/bash" &

env GTK_THEME=Adwaita:dark xfce4-terminal --title="Drone Sim (PX4)" -x bash -c "echo '🚁 Drone_sim 컨테이너(PX4)에 접속 중...'; docker exec -it drone_sim /bin/bash" &

# =================================================================
# 3. 메인 화면은 기존처럼 통합 로그 출력
# =================================================================
echo "----------------------------------------------------------------------"
echo "📄 전체 로그를 출력합니다. (환경을 종료하려면 여기서 Ctrl + C 를 누르세요)"
echo "----------------------------------------------------------------------"
docker compose -f "${COMPOSE_FILE}" logs -f