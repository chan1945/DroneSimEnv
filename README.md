# Docker container env for Drone simulation

## Prerequisites (must be installed before running)
- Docker
- NVIDIA Container Toolkit — required to use the GPU inside Docker containers


## How to use

### Build image and Run container

#### Ubuntu
```bash
cd DroneSimEnv/Docker
./run-ubuntu.sh
```

### WSL2 (Window)
```bash
cd DroneSimEnv/Docker
./run-wsl2.sh
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




