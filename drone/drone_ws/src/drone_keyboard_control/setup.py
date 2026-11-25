# 두 조종 노드의 실행 명령과 ROS 2 패키지 검색에 필요한 파일을 설치합니다.
from setuptools import setup

# package_name은 파이썬 모듈, ROS 패키지 인덱스 및 공유 경로에서 같은 이름을 사용하게 합니다.
package_name = "drone_keyboard_control"

setup(
    name=package_name,
    version="0.1.0",
    packages=[package_name],
    data_files=[
        ("share/ament_index/resource_index/packages", ["resource/" + package_name]),
        ("share/" + package_name, ["package.xml"]),
        ("share/" + package_name + "/launch", ["launch/keyboard_control.launch.xml"]),
    ],
    install_requires=["setuptools"],
    maintainer="chan1945",
    maintainer_email="heechan890@gmail.com",
    description="Keyboard teleoperation and PX4 offboard control for DroneSimEnv SITL.",
    license="Unspecified",
    tests_require=["pytest"],
    entry_points={
        "console_scripts": [
            "keyboard_teleop = drone_keyboard_control.keyboard_teleop:main",
            "px4_offboard = drone_keyboard_control.px4_offboard:main",
        ],
    },
)
