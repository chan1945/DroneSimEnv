# Simulation settings

`simulation/simulation.yml` defines the simulation container's tmux session,
PX4 model, Gazebo world and PX4 startup command. It uses tmuxinator, matching
the Drone and Ground startup configurations.

Change the exports in `pre_window` to select a model and world:

```yaml
# pre_window: Set the environment before the commands in each window.
# PX4_SIM_MODEL: Select the PX4 airframe associated with the Gazebo model.
# PX4_GZ_WORLD: Select a built-in world by filename without the .sdf suffix.
# GZ_IP: Use the loopback address for Gazebo Transport communication.
pre_window:
  - export PX4_SIM_MODEL=gz_x500
  - export PX4_GZ_WORLD=default
  - export GZ_IP=127.0.0.1
```

Models must have matching PX4 airframes and Gazebo model resources in the
simulation image. The default `gz_x500` selects x500. World names refer to
`/DroneSimEnv/PX4-Autopilot/Tools/simulation/gz/worlds/<name>.sdf`; for example,
`default`, `walls` and `windy`. The settings select PX4's built-in resources.

`sim_run.sh` mounts the repository YAML read-only at
`/DroneSimEnv/simulation.yml`. Stop and rerun `sim_run.sh` after editing the
YAML; model, world and window changes do not require an image rebuild. Run
`./tools/sim_build.sh` once after adopting this startup configuration to install
tmuxinator in the simulation image. Running the image without the bind mount
uses the default YAML copied into the image at build time.

The YAML registers missing group names before creating the `simulation`
session. Window `0` (`shell`) starts in `/DroneSimEnv/simulation_ws`. Window `1`
(`px4`) starts in the PX4 build's `rootfs` directory and is selected initially.
PX4 starts Gazebo using the selected model and world. Closing an xterm window
or reconnecting to the existing session does not launch a second PX4 process.

Empty model/world values and missing world SDF files are reported in the PX4
window before PX4 launches. PX4 reports unknown airframe names in its startup
log. The window retains its shell after the command exits so you can read the
error. Read the recent output with:

```bash
docker exec simulation tmux capture-pane -p -J -S -100 -t simulation:px4
```

For errors that prevent tmuxinator from creating the session, such as invalid
YAML syntax, inspect the container startup log:

```bash
docker logs simulation
```
