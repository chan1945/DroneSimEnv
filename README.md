# Docker container env for Drone simulation (PX4 SITL)

## Prerequisites (must be installed before running)
- Docker
- NVIDIA Container Toolkit — required to use the GPU inside Docker containers
  https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/
- xterm — opens a terminal window on the Ubuntu GNOME or WSL2 host

Install xterm before running the project:

```bash
sudo apt-get update
sudo apt-get install -y xterm
```

## Demo Video

[![Watch the demo](https://img.youtube.com/vi/C68um9y9g6o/0.jpg)](https://www.youtube.com/watch?v=C68um9y9g6o)

## How to use
### clone the repository
```bash
git clone https://github.com/chan1945/DroneSimEnv.git
```
### Build images and run containers

Ubuntu and WSL2 use the same commands. `sim_run.sh` detects WSL2 by itself and
uses its graphics settings automatically.

```bash
cd DroneSimEnv/Docker
./sim_build.sh
./sim_run.sh
```

The build script creates the Docker images. The run script then starts the three
containers in the background and opens one `xterm` window for each service:
- `drone`
- `simulation`
- `ground`

Each xterm window connects to a `tmux` session inside its Docker container. This
lets a command keep running after you close that xterm window. Keep the original
terminal window open while using the xterm windows. Press any key in the original
window to stop and remove all three containers. Pressing `Ctrl+C` also removes
them.

### Reconnect to a tmux session

While `sim_run.sh` is still waiting for a key press, reopen a service terminal
with this command in another host terminal:

```bash
docker exec -it drone tmux new-session -A -s drone -c /DroneSimEnv/drone_ws
```

Replace `drone` with `simulation` or `ground` when needed. Their starting
folders are `/DroneSimEnv/simulation_ws` and `/DroneSimEnv/ground_ws`.

### QGroundControl logs

The `ground` container saves QGroundControl output in `/tmp/qgc.log`. Use this
command when QGroundControl does not open or closes unexpectedly:

```bash
docker exec -it ground cat /tmp/qgc.log
```

## Included Software
```
simulation
├─PX4 v1.16.1
├─Gazebo Harmonic

ground
├─QGroundControl

drone
├─ROS2 Humble
├─Micro XRCE DDS Agent v2.4.3
```

## !!warning!!
DroneSimEnv uses the nvcr.io/nvidia/cuda:12.6.3-cudnn-runtime-ubuntu22.04 image as its base image to ensure that the implemented code remains compatible with the actual hardware platform, the Jetson Orin Nano, which supports CUDA 12.6.
