# 키 조합의 속도 계산과 실제 Tk 이벤트가 생성하는 ROS 2 메시지를 검증한다.
import math
import os
import tkinter as tk
import unittest
from unittest.mock import patch

import rclpy
from geometry_msgs.msg import TwistStamped

from drone_keyboard_control.keyboard_teleop import KeyboardTeleop, velocity_for_keys


class KeyboardTests(unittest.TestCase):
    """화면 없는 키 계산 검사와 화면을 사용하는 조종 창 검사를 분리한다."""

    def test_key_chords(self):
        """단독 키, 수평·수직 조합과 반대 키의 속도 및 회전 부호를 확인한다."""
        # diagonal은 두 이동 축으로 2 m/s를 나누었을 때 한 축의 속력이다.
        diagonal = 2 / math.sqrt(2)
        # keys와 expected는 각각 누른 키 집합과 (앞·왼쪽·위·왼쪽 회전) 목표값이다.
        for keys, expected in (
            ({"s", "a"}, (-diagonal, diagonal, 0, 0)),
            ({"w", "d", "q"}, (diagonal, -diagonal, 0, math.pi / 4)),
            ({"w", "shift_r", "e"}, (diagonal, 0, diagonal, -math.pi / 4)),
            ({"shift_l", "shift_r"}, (0, 0, 2, 0)),
            ({"control_r"}, (0, 0, -2, 0)),
            ({"w", "s", "a", "d", "shift_l", "control_l", "q", "e"}, (0, 0, 0, 0)),
        ):
            with self.subTest(keys=keys):
                self.assertEqual(velocity_for_keys(keys), expected)

    @unittest.skipUnless(os.environ.get("DISPLAY"), "Tk 키 이벤트 검사에는 X11 화면이 필요합니다.")
    def test_tk_key_events_and_focus_loss(self):
        """실제 Tk 바인딩을 거쳐 발생한 명령을 캡처하고 시동 서비스 자동 반복을 검사한다."""
        # window는 테스트 전용 Tk 창이며 테스트 종료 시 예약된 Tk 콜백과 함께 제거한다.
        window = tk.Tk()
        self.addCleanup(window.destroy)
        rclpy.init(args=["--ros-args", "-r", "__ns:=/keyboard_input_test"])
        self.addCleanup(rclpy.shutdown)
        # publisher와 client는 전송 직전의 ROS 메시지를 검사하고 외부 기체와 격리한다.
        with patch.object(KeyboardTeleop, "create_publisher") as publisher, \
                patch.object(KeyboardTeleop, "create_client") as client:
            # node는 실제 화면·타이머·키 바인딩을 구성하는 테스트용 ROS 노드다.
            node = KeyboardTeleop(window)
        self.addCleanup(node.destroy_node)
        window.update()
        window.focus_force()
        window.update()
        window.event_generate("<KeyPress-w>")
        window.event_generate("<KeyPress-Shift_L>")
        # moving은 마지막 키 누름에 발행된 기수 기준 3차원 속도 메시지다.
        moving = publisher.return_value.publish.call_args.args[0]
        self.assertIsInstance(moving, TwistStamped)
        self.assertEqual(moving.header.frame_id, "base_footprint")
        self.assertAlmostEqual(moving.twist.linear.x, math.sqrt(2))
        self.assertAlmostEqual(moving.twist.linear.z, math.sqrt(2))
        window.event_generate("<KeyRelease-Shift_L>")
        window.update_idletasks()
        # forward는 Shift만 뗀 순간에 W 입력이 남아 생성되는 전진 명령이다.
        forward = publisher.return_value.publish.call_args.args[0].twist.linear
        self.assertEqual((forward.x, forward.y, forward.z), (2.0, 0.0, 0.0))
        window.event_generate("<FocusOut>")
        # neutral은 포커스를 잃는 이벤트 처리 중에 즉시 발행한 중립 명령이다.
        neutral = publisher.return_value.publish.call_args.args[0]
        self.assertEqual(neutral.twist, TwistStamped().twist)

        window.event_generate("<KeyPress-p>", time=100)
        node.check_arm()  # 서비스 응답이 이미 왔어도 같은 키 자동 반복은 무시해야 한다.
        window.event_generate("<KeyRelease-p>", time=110)
        window.event_generate("<KeyPress-p>", time=110)
        window.update_idletasks()
        client.return_value.call_async.assert_called_once()
        window.event_generate("<KeyRelease-p>", time=120)
        window.update_idletasks()
        window.event_generate("<KeyPress-p>", time=140)
        self.assertEqual(client.return_value.call_async.call_count, 2)
