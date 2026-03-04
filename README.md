# Docker container env for Drone simulation

## Prerequisites (must be installed before running)
- Docker
- NVIDIA Container Toolkit — required to use the GPU inside Docker containers


## How to use

### Build image and Run container
```bash
cd DroneSimEnv/Docker
chmod +x ./run-ubuntu.sh
./run-ubuntu.sh
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




