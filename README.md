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
### Build images and run containers

#### Ubuntu
```bash
cd DroneSimEnv/Docker
./sim_build.sh
./sim_run.sh up
```

#### WSL2 (Windows)
```bash
cd DroneSimEnv/Docker
./sim_build.sh
./sim_run.sh up
```

The build script creates the Docker images. The `up` command then starts the three containers in the background and opens terminal windows for:
- `companion`
- `drone_sim`
- `ground`

### Container management commands

Ubuntu:
```bash
cd DroneSimEnv/Docker

./sim_run.sh up
./sim_run.sh logs
./sim_run.sh shell companion
./sim_run.sh shell drone_sim
./sim_run.sh shell ground
./sim_run.sh stop
./sim_run.sh down
```

WSL2:
```bash
cd DroneSimEnv/Docker

./sim_run.sh up
./sim_run.sh logs
./sim_run.sh shell companion
./sim_run.sh shell drone_sim
./sim_run.sh shell ground
./sim_run.sh stop
./sim_run.sh down
```

Command behavior:
- `up`: start containers in detached mode (run `./sim_build.sh` first)
- `logs`: follow container logs; pressing `Ctrl+C` stops log viewing only
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
