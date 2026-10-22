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
./tools/sim_run.sh --world walls --model x500
```

`--world` and `--model` are required. If either is missing, the run script exits
with an error before touching Docker containers. Put downloaded Gazebo Harmonic
resources in these paths before running it:

```text
simulation/simulation_ws/src/simulation_resources/
├── worlds/
│   └── walls/
│       └── walls.sdf
└── drone_models/
    └── x500/
        ├── model.config
        ├── model.sdf
        └── meshes/ ...
```

The world may also be a single `worlds/<name>.sdf` file. Pass the world name
without `.sdf` and the model directory name. Resource names may contain letters,
digits, underscores, and hyphens. The downloaded model must contain a PX4-compatible
Gazebo SDF, including the sensors and motor plugins expected by its PX4 airframe.
The SDF `<world name>` must match `--world` because PX4 uses it for Gazebo service
lookup. PX4 spawns the selected model as `<model directory name>_0`.

The script mounts the host `drone_models` directory over PX4's model directory
and mounts the selected world SDF directly at PX4's world file path, both read-only.
The selected files are used even if their names match built-in PX4 resources.
Place any models referenced by `model://` URIs in `drone_models` as well; built-in
model files are hidden by the mount.

PX4 flight parameters are selected independently of the custom model name.
`--airframe` defaults to `4001`, a quadrotor configuration. Use an appropriate PX4
autostart ID for the vehicle's rotor layout and actuator mapping, for example:

```bash
./tools/sim_run.sh --world walls --model custom_quad --airframe 4001
```

`PX4_SIM_MODEL=gz_custom_quad` tells PX4 to open the mounted
`models/custom_quad/model.sdf`; it does not require a built-in model named
`custom_quad`. The explicit `PX4_SYS_AUTOSTART` setting avoids matching the custom
model name against built-in airframes. Choosing an airframe does not replace the
custom model SDF.

The script starts PX4 SITL and Gazebo in the simulation container's `px4` tmux
window. Use `Ctrl+B`, then `0` to switch to the simulation shell, and `Ctrl+B`,
then `1` to return to PX4. Model and world files are loaded from the host at run
time, so adding or changing them does not require rebuilding the images.

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
