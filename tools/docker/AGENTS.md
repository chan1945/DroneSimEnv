# Dockerfile 코드 스타일 지침
- 현재 디렉터리의 Dockerfile은 해당 코드 스타일을 따라야 합니다.
1. 큰 작업 단위마다 ######################################################################## 구분선 사용
2. 구분선 사이 짧은 섹션 제목사용
3. 패키지는 한 줄에 하나씩 배치
4. 긴 shell command는 \로 줄바꿈
5. WORKDIR, COPY, RUN 순서를 논리적으로 정리




- 예시
```
########################################################################
# base image and basic tools
########################################################################
# This stage contains tools that every DroneSimEnv container needs.
FROM ${CUDA_IMAGE} AS base_amd64

# Do not ask questions while packages are being installed.
ENV DEBIAN_FRONTEND=noninteractive
SHELL ["/bin/bash", "-c"]

# Install shared command-line tools only once.
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    cmake \
    curl \
    git \
    gnupg2 \
    locales \
    lsb-release \
    python3-pip \
    software-properties-common \
    sudo \
    tmux \
    tzdata \
    wget \
    && rm -rf /var/lib/apt/lists/*


########################################################################
# Install ROS 2 Humble
########################################################################
# This stage adds ROS 2 Humble to the shared base image.
FROM base_amd64 AS ros2_humble

# Use UTF-8 text so ROS 2 tools and terminals can handle normal characters.
RUN locale-gen en_US.UTF-8 \
    && update-locale LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
ENV LANG=en_US.UTF-8
ENV LC_ALL=en_US.UTF-8

# Add the official ROS 2 package source, then install ROS 2 and build tools.
RUN curl -fsSL https://raw.githubusercontent.com/ros/rosdistro/master/ros.key \
        -o /usr/share/keyrings/ros-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/ros-archive-keyring.gpg] http://packages.ros.org/ros2/ubuntu $(. /etc/os-release && echo $UBUNTU_CODENAME) main" \
        > /etc/apt/sources.list.d/ros2.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        ros-dev-tools \
        ros-humble-ament-cmake-clang-format \
        ros-humble-bondcpp \
        ros-humble-desktop \
        ros-humble-vision-msgs \
    && rm -rf /var/lib/apt/lists/* \
    && rosdep init \
    && rosdep update \
    && echo "source /opt/ros/humble/setup.bash" >> /root/.bashrc
```
