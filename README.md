# Docker container env for Drone simulation (PX4 SITL)

## Prerequisites (must be installed before running)
- Docker
- NVIDIA Container Toolkit — required to use the GPU inside Docker containers
  https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/


## How to use
### clone the repository
```bash
git clone --recurse-submodules https://github.com/chan1945/DroneSimEnv.git
```
### Build image and Run container

#### Ubuntu
```bash
cd DroneSimEnv/Docker
./run-ubuntu.sh
```

#### WSL2 (Window)
```bash
cd DroneSimEnv/Docker
./run-wsl2.sh
```

If you want to stop the containers without removing them, run the script with the --keep option:
#### Ubuntu
```bash
cd DroneSimEnv/Docker
./run-ubuntu.sh --keep
```
#### WSL2 (Window)
```bash
cd DroneSimEnv/Docker
./run-wsl2.sh --keep
```

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


