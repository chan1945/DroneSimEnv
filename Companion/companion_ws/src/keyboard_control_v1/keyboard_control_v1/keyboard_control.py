#!/usr/bin/env python3

# 키보드 입력을 한 글자씩 읽기 위해 사용한다.
import select
import sys
import termios
import tty

# ROS 2 Python 통신 라이브러리
import rclpy
# 선속도 / 각속도 명령을 담는 표준 메시지
from geometry_msgs.msg import Twist
from rclpy.qos import QoSHistoryPolicy, QoSProfile, QoSReliabilityPolicy
# teleop 활성 상태를 알리는 단순 on/off 메시지
from std_msgs.msg import Bool


# 프로그램 실행 시 터미널에 보여 줄 안내문
HELP_MESSAGE = """
Control PX4 drone with WASDQERF keys
------------------------------------
Movement:
  W/S : Pitch forward/backward
  A/D : Roll left/right
  Q/E : Yaw left/right
  R/F : Throttle up/down

Speed adjustment:
  T/G : Increase/decrease ALL speeds
  Y/H : Increase/decrease only linear
  U/J : Increase/decrease only angular

CTRL-C to quit
"""

# 각 키를 눌렀을 때 어떤 방향 명령을 보낼지 정의한다.
# 형식: (pitch, roll, throttle, yaw)
# 값이 1이면 해당 방향으로 이동, -1이면 반대 방향으로 이동한다.
MOVE_BINDINGS = {
    'w': (1, 0, 0, 0),
    's': (-1, 0, 0, 0),
    'a': (0, -1, 0, 0),
    'd': (0, 1, 0, 0),
    'r': (0, 0, 1, 0),
    'f': (0, 0, -1, 0),
    'q': (0, 0, 0, 1),
    'e': (0, 0, 0, -1),
}

# 속도 자체를 키우거나 줄이는 키 설정이다.
# 형식: (linear scale, angular scale)
# 예를 들어 1.1은 10% 증가, 0.9는 10% 감소를 의미한다.
SPEED_BINDINGS = {
    't': (1.1, 1.1),
    'g': (0.9, 0.9),
    'y': (1.1, 1.0),
    'h': (0.9, 1.0),
    'u': (1.0, 1.1),
    'j': (1.0, 0.9),
}


def get_key(settings) -> str:
    # 터미널을 raw 모드로 바꿔서 Enter 없이도 키 한 글자를 바로 읽는다.
    tty.setraw(sys.stdin.fileno())
    select.select([sys.stdin], [], [], 0)
    key = sys.stdin.read(1)

    # 키를 읽은 뒤에는 원래 터미널 설정으로 되돌린다.
    termios.tcsetattr(sys.stdin, termios.TCSADRAIN, settings)
    return key


def format_vels(speed: float, turn: float) -> str:
    # 현재 선속도/회전속도 배율을 보기 좋게 문자열로 만든다.
    return f'currently:\tspeed {speed:.2f}\tturn {turn:.2f}'


def main(args=None) -> None:
    # 프로그램 종료 후 터미널을 원래 상태로 복구하기 위해 현재 설정을 저장한다.
    settings = termios.tcgetattr(sys.stdin)

    # ROS 2 통신 시작
    rclpy.init(args=args)

    # 이 프로그램의 ROS 2 노드 이름
    node = rclpy.create_node('keyboard_control_v1')

    # 일반적인 reliable QoS 설정
    qos = QoSProfile(
        reliability=QoSReliabilityPolicy.RELIABLE,
        history=QoSHistoryPolicy.KEEP_LAST,
        depth=10,
    )

    # cmd_vel:
    #   실제 속도 명령을 보내는 토픽
    # /teleop/active:
    #   "지금 사람이 키보드로 조종 중이다" 라는 상태를 알려주는 토픽
    cmd_vel_publisher = node.create_publisher(Twist, 'cmd_vel', qos)
    active_publisher = node.create_publisher(Bool, '/teleop/active', qos)

    # 프로그램 시작과 동시에 teleop 활성 상태를 True로 알린다.
    active_msg = Bool()
    active_msg.data = True
    active_publisher.publish(active_msg)

    # 기본 이동 속도와 회전 속도
    speed = 0.5
    turn = 1.0

    # 현재 키 입력으로 결정된 이동 방향 값
    pitch = 0.0
    roll = 0.0
    throttle = 0.0
    yaw = 0.0

    # 일정 횟수마다 도움말을 다시 보여 주기 위한 카운터
    status = 0

    try:
        print(HELP_MESSAGE)
        print(format_vels(speed, turn))

        while True:
            # 키 하나를 읽는다.
            key = get_key(settings)

            if key in MOVE_BINDINGS:
                # 이동 키라면 해당 축의 방향 값을 가져온다.
                pitch, roll, throttle, yaw = MOVE_BINDINGS[key]
            elif key in SPEED_BINDINGS:
                # 속도 조절 키라면 배율만 바꾸고, 실제 이동 명령은 0으로 초기화한다.
                speed *= SPEED_BINDINGS[key][0]
                turn *= SPEED_BINDINGS[key][1]
                print(format_vels(speed, turn))
                pitch = 0.0
                roll = 0.0
                throttle = 0.0
                yaw = 0.0

                if status == 14:
                    print(HELP_MESSAGE)
                status = (status + 1) % 15
            else:
                # 정의되지 않은 키를 누르면 정지 명령으로 처리한다.
                pitch = 0.0
                roll = 0.0
                throttle = 0.0
                yaw = 0.0

                # Ctrl-C를 누르면 루프를 종료한다.
                if key == '\x03':
                    break

            # Twist 메시지에 현재 키 입력 결과를 담는다.
            twist = Twist()

            # linear.x: 전진/후진
            twist.linear.x = pitch * speed
            # linear.y: 좌/우 이동
            twist.linear.y = roll * speed
            # linear.z: 상/하 이동
            # 여기서는 throttle의 부호를 반대로 넣고 있다.
            # 이 값은 이후 브리지 노드에서 PX4의 NED 기준 속도로 변환된다.
            twist.linear.z = -(throttle * speed)
            # angular.z: 좌/우 회전(yaw)
            twist.angular.z = -(yaw * turn)
            cmd_vel_publisher.publish(twist)

            # 키를 누르고 있는 동안 teleop 활성 상태를 계속 True로 보낸다.
            # 브리지 노드는 이 신호를 보고 offboard 제어를 유지한다.
            active_msg = Bool()
            active_msg.data = True
            active_publisher.publish(active_msg)
    except Exception as exc:
        print(exc)
    finally:
        # 종료 직전에는 반드시 0 속도 명령을 보내 드론이 계속 움직이지 않게 한다.
        twist = Twist()
        cmd_vel_publisher.publish(twist)

        # teleop 종료를 알리기 위해 active=False 를 보낸다.
        inactive_msg = Bool()
        inactive_msg.data = False
        active_publisher.publish(inactive_msg)

        # 터미널 상태와 ROS 자원을 정리한다.
        termios.tcsetattr(sys.stdin, termios.TCSADRAIN, settings)
        node.destroy_node()
        rclpy.shutdown()
        print('\nTeleop shutdown. Sent /teleop/active = False')


if __name__ == '__main__':
    # 이 파일을 직접 실행했을 때 main()을 시작한다.
    main()
