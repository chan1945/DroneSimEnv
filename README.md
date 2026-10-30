# Docker container env for Drone simulation (PX4 SITL)

## Prerequisites (must be installed before running)
- Docker
- NVIDIA Container Toolkit — required to use the GPU inside Docker containers
  https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/
- xterm — opens a terminal window on the Ubuntu GNOME or WSL2 host
- Git — downloads the cached external source code before Docker builds images
- Network access — needed when the external source cache is first created

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
cd DroneSimEnv
./tools/sim_build.sh
./tools/sim_run.sh
```

The run script uses PX4's built-in `x500` model and the default Gazebo world
included in the simulation image. Run it without arguments, or use `--help` to
show usage information.

The script starts PX4 SITL and Gazebo in the simulation container's `px4` tmux
window. Use `Ctrl+B`, then `0` to switch to the simulation shell, and `Ctrl+B`,
then `1` to return to PX4.

The Drone terminal uses `drone/drone.yml` to create a tmux window with two
side-by-side panes. The left pane automatically runs `MicroXRCEAgent udp4 -p 8888`
and displays its logs. The right pane opens a shell in `/DroneSimEnv/drone_ws`
and is selected initially. The port matches PX4 SITL's default DDS client port.

Press `Ctrl+B`, then an arrow key to move between panes. Press `Ctrl+B`, then
`Z` to zoom the selected pane or restore the split layout. If the Agent exits,
its pane remains available as a shell so you can inspect its output and restart
it. Reconnecting to the existing `drone` session does not start another Agent.

The build script first prepares external Git sources in `tools/_git_clones`.
It clones PX4 v1.16.2 with its submodules, px4_msgs `release/1.16`, and
Micro-XRCE-DDS-Agent v2.4.3. Later builds reuse valid cached copies and only
download a requested ref when that cache does not have it. Do not edit files in
this folder; the script stops rather than overwriting unexpected changes.

The build script then creates shared CUDA and ROS 2 images. It creates the
three service images from the shared ROS 2 image and copies the prepared source
files into the needed images. This lets Docker reuse the slow ROS 2 installation
layer when only one service changes. The run script starts the three containers
in the background and opens one `xterm` window for each service:
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

QGroundControl output appears in the `qgc` tmux window. Use this command to
read its recent output when QGroundControl does not open or closes unexpectedly:

```bash
docker exec ground tmux capture-pane -p -S -200 -t ground:qgc
```

### QGroundControl settings

See [QGroundControl settings](docs/qgc-settings.md) for default INI configuration
and how settings are reset between runs.

## Included Software
```
simulation
├─PX4 v1.16.2
├─Gazebo Harmonic

ground
├─QGroundControl

drone
├─ROS2 Humble
├─px4_msgs release/1.16
├─Micro XRCE DDS Agent v2.4.3
```

## Image architecture

All images use CUDA 13.3.0. `sim_build.sh` builds them in this order:

```text
nvcr.io/nvidia/cuda:13.3.0-cudnn-runtime-ubuntu22.04
└─ dronesimenv/base_amd64:cuda13.3.0
   └─ dronesimenv/ros2_humble:cuda13.3.0-humble
      ├─ dronesimenv/drone:cuda13.3.0
      ├─ dronesimenv/simulation:cuda13.3.0
      └─ dronesimenv/ground:cuda13.3.0
```

Run `./tools/sim_build.sh` again after changing a Dockerfile. Docker reuses
unchanged layers, so later builds are faster.

## CUDA requirement

The host NVIDIA driver and NVIDIA Container Toolkit must support CUDA 13.3.0.
Check this requirement before building or running DroneSimEnv.
