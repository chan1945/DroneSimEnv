# 조종 창의 키 누름과 해제를 ROS 2 속도 명령과 비동기 시동 요청으로 전달합니다.
import math
import time
import tkinter as tk
from tkinter import ttk

import rclpy
from geometry_msgs.msg import TwistStamped
from rclpy.node import Node
from std_srvs.srv import Trigger


# CONTROL_KEYS에는 조종에 사용하는 Tk 키 이름만 소문자로 저장합니다.
CONTROL_KEYS = {
    "w", "s", "a", "d", "q", "e", "p", "shift_l", "shift_r", "control_l", "control_r",
}


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
    """Tk 이벤트 루프 하나에서 키 상태, 속도 발행과 ROS 서비스 응답을 처리합니다."""

    def __init__(self, window):
        """window에 조종 화면을 구성하고 키 상태와 ROS 통신을 초기화합니다."""
        super().__init__("keyboard_teleop")
        # window는 입력을 받는 최상위 Tk 창이며 ROS 처리 주기도 예약합니다.
        self.window = window
        # pressed는 실제로 누른 키 집합이며 pending_releases는 X11 자동 반복 판별용 예약입니다.
        self.pressed = set()
        self.pending_releases = {}
        # commands는 기수 기준 속도 토픽에 최신 명령 하나를 보관합니다.
        self.commands = self.create_publisher(TwistStamped, "teleop/cmd_vel", 1)
        # arm_client와 arm_future는 동시에 하나의 시동 요청만 비동기로 처리합니다.
        self.arm_client = self.create_client(Trigger, "teleop/arm")
        self.arm_future = None
        # arm_deadline은 서버가 요청 도중 사라졌을 때 새 요청을 허용할 단조 시각입니다.
        self.arm_deadline = 0.0
        # status는 요청 진행과 PX4 응답을 조종 창 하단에 표시합니다.
        self.status = tk.StringVar(master=window, value="Click this window to control the drone.")
        window.title("Drone keyboard control")
        ttk.Label(window, padding=12, justify="left", text=(
            "P    Arm\n"
            "W / S    Forward / Backward       A / D    Left / Right\n"
            "Shift / Ctrl    Ascend / Descend       Q / E    Turn left / right"
        )).pack(anchor="w")
        ttk.Label(window, padding=12, textvariable=self.status, wraplength=420).pack(anchor="w")
        window.bind("<KeyPress>", self.press)
        window.bind("<KeyRelease>", self.release)
        window.bind("<FocusOut>", self.neutralize)
        window.protocol("WM_DELETE_WINDOW", window.quit)
        window.after(0, self.tick)

    def press(self, event):
        """event.keysym의 첫 누름만 반영하고 같은 시각에 생성된 자동 반복을 제거합니다."""
        # key는 Shift나 Caps Lock으로 대문자가 되어도 동일한 조종 키로 인식합니다.
        key = event.keysym.lower()
        if key not in CONTROL_KEYS:
            return
        # pending은 직전 해제 시각과 Tk 예약 ID로 실제 재누름과 X11 반복을 구분합니다.
        pending = self.pending_releases.pop(key, None)
        if pending is not None:
            self.window.after_cancel(pending[1])
            if pending[0] != event.time:
                self.pressed.discard(key)
        if key in self.pressed:
            return
        self.pressed.add(key)
        if key == "p":
            self.request_arm()
        else:
            self.publish_command()

    def release(self, event):
        """event의 해제를 한 이벤트 묶음만 미뤄 자동 반복으로 생성된 눌림을 기다립니다."""
        # key는 해제를 기다리는 물리 키이며 키마다 하나의 예약만 허용합니다.
        key = event.keysym.lower()
        if key in self.pressed and key not in self.pending_releases:
            # callback_id로 바로 뒤에 반복 누름이 오면 이 해제 예약을 취소합니다.
            callback_id = self.window.after_idle(self.finish_release, key)
            self.pending_releases[key] = (event.time, callback_id)

    def finish_release(self, key):
        """반복이 아닌 key 해제를 확정해 해당 축을 즉시 갱신합니다."""
        self.pending_releases.pop(key)
        self.pressed.discard(key)
        self.publish_command()

    def neutralize(self, event=None):
        """포커스 해제 이벤트(event)나 종료 시 모든 예약과 눌린 키를 비우고 중립을 보냅니다."""
        # pending은 각 키의 (해제 시각, 예약 ID) 쌍입니다.
        for pending in self.pending_releases.values():
            self.window.after_cancel(pending[1])
        self.pending_releases.clear()
        self.pressed.clear()
        if rclpy.ok():
            self.publish_command()

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
            self.status.set("Arm service unavailable. Check px4_offboard, then press P again.")
            return
        self.arm_future = self.arm_client.call_async(Trigger.Request())
        self.arm_deadline = time.monotonic() + 15.0
        self.status.set("Waiting for PX4 to confirm arming...")

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
                self.status.set(f"{outcome}: {response.message}")
            except Exception as error:
                # error는 서비스 통신 예외이며 다음 P 입력으로 다시 요청할 수 있습니다.
                self.status.set(f"Arm service error: {error}")
            self.arm_future = None
        elif time.monotonic() >= self.arm_deadline:
            self.arm_client.remove_pending_request(self.arm_future)
            self.arm_future = None
            self.status.set("Arm response timed out. Check PX4 status.")

    def tick(self):
        """50 ms마다 ROS 응답을 비차단 처리하고 중립을 포함한 현재 명령을 발행합니다."""
        if not rclpy.ok():
            self.window.quit()
            return
        rclpy.spin_once(self, timeout_sec=0.0)
        self.check_arm()
        self.publish_command()
        self.window.after(50, self.tick)


def main(args=None):
    """args의 ROS 인자를 적용해 창을 열고 종료 시 중립 명령과 자원 정리를 수행합니다."""
    # window는 ROS 초기화 전에 열어 디스플레이 연결 실패를 즉시 보고합니다.
    try:
        window = tk.Tk()
    except tk.TclError as error:
        # error는 X11/WSLg 연결 실패와 같이 창을 열 수 없는 원인을 보관합니다.
        raise SystemExit(f"Cannot open keyboard control window: {error}") from error
    rclpy.init(args=args)
    # node는 Tk 메인 스레드에 조종 및 ROS 콜백을 등록합니다.
    node = KeyboardTeleop(window)
    try:
        window.mainloop()
    except KeyboardInterrupt:
        pass
    finally:
        node.neutralize()
        node.destroy_node()
        window.destroy()
        if rclpy.ok():
            rclpy.shutdown()
