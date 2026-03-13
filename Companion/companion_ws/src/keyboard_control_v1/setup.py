from glob import glob

from setuptools import find_packages, setup

package_name = 'keyboard_control_v1'

setup(
    name=package_name,
    version='0.0.1',
    packages=find_packages(exclude=['test']),
    data_files=[
        ('share/ament_index/resource_index/packages', ['resource/' + package_name]),
        ('share/' + package_name, ['package.xml']),
        ('share/' + package_name + '/launch', glob('launch/*.launch.py')),
    ],
    install_requires=['setuptools'],
    zip_safe=True,
    maintainer='gnu01',
    maintainer_email='gnu01@todo.todo',
    description='ROS 2 Python keyboard teleoperation node for PX4 drones.',
    license='Apache-2.0',
    entry_points={
        'console_scripts': [
            'cmd_vel_px4_bridge = keyboard_control_v1.cmd_vel_px4_bridge:main',
            'keyboard_control = keyboard_control_v1.keyboard_control:main',
        ],
    },
)
