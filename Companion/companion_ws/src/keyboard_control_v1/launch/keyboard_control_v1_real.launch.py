from launch import LaunchDescription
from launch_ros.actions import Node


def generate_launch_description() -> LaunchDescription:
    return LaunchDescription([
        Node(
            package='keyboard_control_v1',
            executable='cmd_vel_px4_bridge',
            name='cmd_vel_px4_bridge',
            output='screen',
        ),
    ])
