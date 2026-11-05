# RViz2

RViz2 starts automatically in the Drone container when `sim_run.sh` launches
the simulation with a GUI display available. ROS 2 Humble's desktop package
already includes RViz2; no additional installation is required for the current
Drone image.

`drone/drone.yml` defines a separate `rviz` tmux window that runs `rviz2` using
the ROS environment loaded by the container shell. The `main` window keeps the
DDS Agent and working shell side by side, with the working shell selected
initially. Press `Ctrl+B`, then `1` to view RViz output, or `Ctrl+B`, then `0`
to return to the main window.

The existing GPU, X11 and WSLg options in `sim_run.sh` also apply to RViz2.
When neither `DISPLAY` nor `WAYLAND_DISPLAY` is set, the RViz window prints a
message explaining that startup was skipped. RViz can start before PX4 or
sensor topics become available, so startup does not add a fixed delay.

Closing and reopening the xterm terminal reconnects to the same tmux session
and does not launch another RViz process. Closing RViz leaves its tmux shell
available for inspecting logs or manually running `rviz2` again. Stopping
`sim_run.sh` removes the Drone container and terminates RViz with it.

Read the latest RViz output from another host terminal with:

```bash
docker exec drone tmux capture-pane -p -J -S -100 -t drone:rviz
```

RViz initially opens its default view. Displaying the simulated drone, depth
images or point clouds requires suitable ROS topics and coordinate transforms
(TF). The `gz_x500_depth` Gazebo sensor data needs a ROS-Gazebo bridge before
RViz can subscribe to it. Configure the RViz displays and Fixed Frame for the
data you publish. This startup configuration launches the viewer only.

Run `./tools/sim_build.sh` after changing `drone/drone.yml`, because the Drone
image includes a copy of this file. Then run `./tools/sim_run.sh`.
