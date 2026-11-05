# ROS-Gazebo bridge

The Simulation image installs `ros-humble-ros-gzharmonic` after PX4's setup
script registers the OSRF repository and installs Gazebo Harmonic. The Drone
image contains the Micro XRCE-DDS Agent, PX4 message definitions and RViz2.

There are two separate data paths:

- Gazebo sensors → `ros_gz_bridge` in Simulation → ROS 2 topics → Drone nodes
  and RViz2.
- PX4 → Micro XRCE-DDS Agent in Drone → PX4 ROS 2 topics such as `/fmu/out/*`.

`simulation/simulation.yml` starts `ros_gz_bridge parameter_bridge` in tmux
window `2` (`bridge`), using `/DroneSimEnv/ros_gz_bridge.yaml`. The bridge node
is named `gazebo_bridge`. Press `Ctrl+B`, then `2` in the Simulation terminal
to inspect it. The initial selected window remains `px4`.

The repository file `simulation/ros_gz_bridge.yaml` maps the Gazebo topics
verified with the current `gz_x500_depth` model to these ROS 2 topics:

| Gazebo topic | ROS 2 topic | ROS message type |
|---|---|---|
| `/clock` | `/clock` | `rosgraph_msgs/msg/Clock` |
| `/depth_camera` | `/camera/depth/image_raw` | `sensor_msgs/msg/Image` |
| `/camera_info` | `/camera/depth/camera_info` | `sensor_msgs/msg/CameraInfo` |
| `/depth_camera/points` | `/camera/depth/points` | `sensor_msgs/msg/PointCloud2` |

All mappings use `GZ_TO_ROS`. The clock is bridged continuously. Sensor
mappings use `lazy: true`, so the bridge subscribes to Gazebo sensor data only
while ROS subscribers are present. Sensor publisher queues hold one message
to avoid accumulating large images or point clouds. Models without these
sensors still provide the clock, but do not produce the corresponding sensor
messages.

`sim_run.sh` mounts the mapping file read-only and checks it exists before
replacing containers. The Simulation image includes a default copy for direct
image execution. Edit the repository mapping and restart `sim_run.sh` to apply
changes without rebuilding. YAML topic names are literal strings; environment
variables in that file are not expanded. If you change models or sensor
topics, inspect `gz topic -l` in Simulation and update the mappings as needed.
The default `/clock` mapping assumes a single Gazebo world; if Gazebo only
advertises `/world/<world>/clock`, use that as `gz_topic_name` while retaining
`/clock` as `ros_topic_name`.

All services use host networking and IPC. `sim_run.sh` passes the host's
`ROS_DOMAIN_ID` to all containers, defaulting to `0` when it is unset. For
example, use `ROS_DOMAIN_ID=7 ./tools/sim_run.sh` to run all services in domain
7. ROS consumers must use the same domain. RViz2 uses `/clock` through
`use_sim_time=true`; configure other simulation-time consumers similarly.

Check the bridge log:

```bash
docker exec simulation tmux capture-pane -p -J -S -100 -t simulation:bridge
```

Check topics from the Drone container:

```bash
docker exec drone bash -ic 'ros2 topic list'
docker exec drone bash -ic 'ros2 topic echo /clock rosgraph_msgs/msg/Clock --once'
docker exec drone bash -ic 'ros2 topic echo /camera/depth/points sensor_msgs/msg/PointCloud2 --once --field header --qos-reliability best_effort'
```

A listed ROS topic confirms the bridge publisher exists. Receiving messages
confirms Gazebo is actually producing the sensor data. Point cloud viewing in
RViz also needs a matching Fixed Frame or suitable TF transforms; see
[RViz2](rviz.md). No synthetic robot transforms are published by this setup.

After moving the package installation, rebuild both Drone and Simulation with
`./tools/sim_build.sh`, then run `./tools/sim_run.sh`.
