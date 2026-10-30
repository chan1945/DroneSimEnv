# QGroundControl settings

`ground/QGroundControl.ini` provides the default QGC 5.0.8 settings, including
UDP auto-connect on MAVLink port 14550. `sim_run.sh` mounts this default file
read-only. Before starting QGC, `ground/ground.yml.erb` copies it to
`/home/qgcuser/.config/QGroundControl/QGroundControl.ini`, replacing any existing
user INI on each startup. The copy and QGC both run as `qgcuser`.

Settings changed in QGC are stored only inside the running container. Stopping
`sim_run.sh` removes the containers and their user settings. The next run starts
from the repository defaults again. Reconnecting to an existing tmux session
keeps the running QGC and does not copy the INI again.

Edit `ground/QGroundControl.ini` to change the defaults for the next run; INI
changes do not require rebuilding the image. Rebuild the ground image once
after updating the startup configuration, using `./tools/sim_build.sh`.

Docker volumes from the previous settings implementation are no longer used
and are not automatically deleted.
