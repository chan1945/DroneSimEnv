# Drone 터미널 입력을 ROS 2 속도 명령과 비동기 시동 요청으로 전달합니다.
import math
import os
import signal
import termios
import time

import rclpy
from geometry_msgs.msg import TwistStamped
from rclpy.node import Node
from rclpy.signals import SignalHandlerOptions
from std_srvs.srv import Trigger
from Xlib import display, error

from .xterm_input import XtermInput, quiet_terminal


def velocity_for_keys(pressed):
    """pressed에 담긴 물리 키 조합을 앞·왼쪽·위 선속도와 왼쪽 회전 각속도로 변환합니다."""
    # forward와 left는 각 수평축의 양·음 방향 키가 동시에 눌리면 0이 됩니다.
    forward = ("w" in pressed) - ("s" in pressed)
    left = ("a" in pressed) - ("d" in pressed)
    # up은 좌우 어느 쪽 Shift/Ctrl을 누르든 상승/하강을 한 번만 반영합니다.
    up = bool(pressed & {"shift_l", "shift_r"}) - bool(pressed & {"control_l", "control_r"})
    # length와 scale로 세 축을 함께 정규화해 대각선에서도 목표 속력을 2 m/s로 유지합니다.
    length = math.hypot(forward, left, up)
    scale = 2.0 / length if length else 0.0
    # yaw_rate는 이동과 독립적으로 왼쪽/오른쪽 회전에 초당 45도를 적용합니다.
    yaw_rate = (("q" in pressed) - ("e" in pressed)) * math.pi / 4.0
    return forward * scale, left * scale, up * scale, yaw_rate


class KeyboardTeleop(Node):
    """키 입력을 속도 토픽과 비동기 시동 서비스로 연결합니다."""

    def __init__(self):
        """조종 키 상태와 ROS 통신을 초기화합니다."""
        super().__init__("keyboard_teleop")
        # pressed는 활성 pane에서 현재 누르고 있는 조종 키입니다.
        self.pressed = set()
        # commands는 기수 기준 속도 토픽에 최신 명령 하나를 보관합니다.
        self.commands = self.create_publisher(TwistStamped, "teleop/cmd_vel", 1)
        # arm_client와 arm_future는 동시에 하나의 시동 요청만 비동기로 처리합니다.
        self.arm_client = self.create_client(Trigger, "teleop/arm")
        self.arm_future = None
        # arm_deadline은 서버가 요청 도중 사라졌을 때 새 요청을 허용할 단조 시각입니다.
        self.arm_deadline = 0.0
        # next_publish는 키 변화가 없을 때에도 명령을 발행할 다음 시각입니다.
        self.next_publish = 0.0

    def update_input(self, pressed, arm):
        """키 변화 즉시 속도를 발행하고 P의 첫 누름만 시동 요청으로 전달합니다."""
        # now는 정기 발행 간격을 계산하는 단조 시각입니다.
        now = time.monotonic()
        if pressed != self.pressed or now >= self.next_publish:
            self.pressed = pressed
            self.publish_command()
            self.next_publish = now + 0.05
        if arm:
            self.request_arm()

    def publish_command(self):
        """현재 키 상태를 base_footprint 기준의 시각이 포함된 속도 명령으로 발행합니다."""
        # command의 선속도는 m/s, 각속도는 rad/s이며 사용하지 않는 축은 기본값 0입니다.
        command = TwistStamped()
        command.header.stamp = self.get_clock().now().to_msg()
        command.header.frame_id = "base_footprint"
        (command.twist.linear.x, command.twist.linear.y, command.twist.linear.z,
         command.twist.angular.z) = velocity_for_keys(self.pressed)
        self.commands.publish(command)

    def request_arm(self):
        """시동 서비스에 비동기 요청을 보내고 대기 중에도 조종 입력을 계속 처리합니다."""
        if self.arm_future is not None:
            return
        if not self.arm_client.service_is_ready():
            self.get_logger().warning("Arm service unavailable. Check px4_offboard, then press P again.")
            return
        self.arm_future = self.arm_client.call_async(Trigger.Request())
        self.arm_deadline = time.monotonic() + 15.0
        self.get_logger().info("Waiting for PX4 to confirm arming...")

    def check_arm(self):
        """서비스 결과를 표시하고 서버가 응답하지 않으면 로컬 대기 요청을 정리합니다."""
        if self.arm_future is None:
            return
        if self.arm_future.done():
            try:
                # response는 서버가 확인한 시동 성공 여부와 그 이유를 담습니다.
                response = self.arm_future.result()
                # outcome은 사용자가 응답의 성공 여부를 즉시 알 수 있게 표시합니다.
                outcome = "Armed" if response.success else "Arm failed"
                self.get_logger().info(f"{outcome}: {response.message}")
            except Exception as error:
                # error는 서비스 통신 예외이며 다음 P 입력으로 다시 요청할 수 있습니다.
                self.get_logger().error(f"Arm service error: {error}")
            self.arm_future = None
        elif time.monotonic() >= self.arm_deadline:
            self.arm_client.remove_pending_request(self.arm_future)
            self.arm_future = None
            self.get_logger().warning("Arm response timed out. Check PX4 status.")


def main(args=None):
    """조종 pane에서 X11과 ROS를 처리하고 종료 전에 중립을 발행합니다."""
    # pane은 launch가 실행된 tmux pane의 고유 ID입니다.
    pane = os.environ.get("TMUX_PANE")
    if not pane:
        raise SystemExit("Start keyboard control in the Drone xterm opened by sim_run.sh.")
    try:
        # connection은 기존 xterm의 X 서버를 관찰하는 연결입니다.
        connection = display.Display()
        try:
            # keyboard는 launch를 시작한 창과 pane에 입력 수신을 한정합니다.
            keyboard = XtermInput(connection, pane)
            with quiet_terminal() as tty:
                # 기존 터미널의 Ctrl+C와 launch의 SIGTERM 모두 정리 경로로 처리합니다.
                signal.signal(signal.SIGTERM, signal.default_int_handler)
                rclpy.init(args=args, signal_handler_options=SignalHandlerOptions.NO)
                # node는 키 상태에 따른 속도 및 시동 요청을 발행합니다.
                node = KeyboardTeleop()
                try:
                    node.get_logger().info(
                        "Fly in this pane: P arm, W/S forward/back, A/D left/right, "
                        "Shift/Ctrl climb/descend, Q/E turn. Ctrl+C stops the launch."
                    )
                    while rclpy.ok():
                        # pressed와 arm은 이번 입력 주기의 키 상태와 P 누름 여부입니다.
                        pressed, arm = keyboard.read()
                        node.update_input(pressed, arm)
                        rclpy.spin_once(node, timeout_sec=0.0)
                        node.check_arm()
                        termios.tcflush(tty, termios.TCIFLUSH)
                        time.sleep(0.01)
                finally:
                    if rclpy.ok():
                        node.pressed.clear()
                        node.publish_command()
                    node.destroy_node()
                    rclpy.try_shutdown()
        finally:
            connection.close()
    except KeyboardInterrupt:
        pass
    except (OSError, RuntimeError, termios.error,
            error.DisplayError, error.ConnectionClosedError, error.XError) as exc:
        # exc는 창 연결, tmux pane 또는 터미널 설정 오류의 원인을 알려 줍니다.
        raise SystemExit(f"Cannot read Drone xterm input: {exc}") from exc
