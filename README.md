# Docker container env for Drone simulation (PX4 SITL)

## Prerequisites (must be installed before running)
- Docker
- NVIDIA Container Toolkit — required to use the GPU inside Docker containers
  https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/

## Demo Video

[![Watch the demo](https://img.youtube.com/vi/C68um9y9g6o/0.jpg)](https://www.youtube.com/watch?v=C68um9y9g6o)

## How to use
### clone the repository
```bash
git clone --recurse-submodules https://github.com/chan1945/DroneSimEnv.git
```
### Build image and run containers

#### Ubuntu
```bash
cd DroneSimEnv/Docker
./run-ubuntu.sh up
```

#### WSL2 (Windows)
```bash
cd DroneSimEnv/Docker
./run-wsl2.sh up
```

The `up` command builds the Docker images, starts the three containers in the background, and opens terminal windows for:
- `companion`
- `drone_sim`
- `ground`

### Container management commands

Ubuntu:
```bash
cd DroneSimEnv/Docker

./run-ubuntu.sh up
./run-ubuntu.sh logs
./run-ubuntu.sh shell companion
./run-ubuntu.sh shell drone_sim
./run-ubuntu.sh shell ground
./run-ubuntu.sh stop
./run-ubuntu.sh down
```

WSL2:
```bash
cd DroneSimEnv/Docker

./run-wsl2.sh up
./run-wsl2.sh logs
./run-wsl2.sh shell companion
./run-wsl2.sh shell drone_sim
./run-wsl2.sh shell ground
./run-wsl2.sh stop
./run-wsl2.sh down
```

Command behavior:
- `up`: build images and start containers in detached mode
- `logs`: follow Docker Compose logs; pressing `Ctrl+C` stops log viewing only
- `shell <service>`: open an interactive shell inside `companion`, `drone_sim`, or `ground`
- `stop`: stop containers while keeping them
- `down`: stop and remove containers

## Included Software
```
drone_sim
├─PX4 v1.16.1
├─Gazebo Harmonic

ground
├─QGroundControl

companion
├─ROS2 Humble
├─Micro XRCE DDS Agent v2.4.3
```

## !!warning!!
DroneSimEnv uses the nvcr.io/nvidia/cuda:12.6.3-cudnn-runtime-ubuntu22.04 image as its base image to ensure that the implemented code remains compatible with the actual hardware platform, the Jetson Orin Nano, which supports CUDA 12.6.
