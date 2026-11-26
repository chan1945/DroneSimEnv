# X11 키 시퀀스가 ROS 2 속도 명령과 시동 요청으로 변환되는지 검증합니다.
import math
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

from Xlib import X, XK
import rclpy
from geometry_msgs.msg import TwistStamped

from drone_keyboard_control.keyboard_teleop import KeyboardTeleop, velocity_for_keys
from drone_keyboard_control.xterm_input import XtermInput


class KeyboardTests(unittest.TestCase):
    """키 조합 계산과 X11 포커스·반복 이벤트의 처리 결과를 검증합니다."""

    def test_key_chords(self):
        """단독 키, 수평·수직 조합과 반대 키의 속도 및 회전 부호를 확인합니다."""
        # diagonal은 두 이동 축으로 2 m/s를 나누었을 때 한 축의 속력입니다.
        diagonal = 2 / math.sqrt(2)
        # keys와 expected는 각각 누른 키 집합과 (앞·왼쪽·위·왼쪽 회전) 목표값입니다.
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

    def test_terminal_key_events_and_focus_loss(self):
        """X11 입력과 시동 요청을 실제 ROS 노드의 발행 직전까지 확인합니다."""
        # connection과 window는 같은 xterm이 포커스를 유지하는 X11 연결을 흉내 냅니다.
        connection = Mock()
        window = connection.create_resource_object.return_value
        window.id = 100
        window.query_tree.return_value.children = []
        connection.get_input_focus.return_value.focus = window
        connection.keycode_to_keysym.side_effect = (
            lambda code, level: {25: XK.XK_w, 33: XK.XK_p, 50: XK.XK_Shift_L}.get(code)
        )
        connection.query_keymap.return_value = [0] * 32
        with patch("drone_keyboard_control.xterm_input.active_clients", return_value={123}), \
                patch("pathlib.Path.read_bytes", return_value=b"WINDOWID=100\0"):
            # keyboard는 모의 창 이벤트를 실제 입력 처리 코드로 해석합니다.
            keyboard = XtermInput(connection, "%1")
            connection.pending_events.return_value = 0
            keyboard.read()

        rclpy.init(args=["--ros-args", "-r", "__ns:=/keyboard_input_test"])
        self.addCleanup(rclpy.shutdown)
        # publisher와 client는 ROS 메시지와 서비스 요청을 외부 통신 없이 기록합니다.
        with patch.object(KeyboardTeleop, "create_publisher") as publisher, \
                patch.object(KeyboardTeleop, "create_client") as client:
            # node는 조종 상태를 속도와 시동 요청으로 변환하는 테스트용 ROS 노드입니다.
            node = KeyboardTeleop()
        self.addCleanup(node.destroy_node)

        def update(*events):
            """X 서버 이벤트 묶음을 읽고 ROS 노드에 전달합니다."""
            connection.pending_events.return_value = len(events)
            connection.next_event.side_effect = events
            with patch("drone_keyboard_control.xterm_input.active_clients", return_value={123}):
                node.update_input(*keyboard.read())

        def key(kind, code, timestamp):
            """물리 키코드와 X11 타임스탬프로 실제 키 이벤트를 흉내 냅니다."""
            return SimpleNamespace(type=kind, detail=code, time=timestamp, send_event=False)

        update(key(X.KeyPress, 25, 10), key(X.KeyPress, 50, 11))
        # moving은 W+Shift에 대해 발행된 기수 기준 속도 메시지입니다.
        moving = publisher.return_value.publish.call_args.args[0]
        self.assertIsInstance(moving, TwistStamped)
        self.assertEqual(moving.header.frame_id, "base_footprint")
        self.assertAlmostEqual(moving.twist.linear.x, math.sqrt(2))
        self.assertAlmostEqual(moving.twist.linear.z, math.sqrt(2))

        update(key(X.KeyRelease, 50, 20))
        # forward는 Shift를 뗀 후 W가 남아 있는 전진 명령입니다.
        forward = publisher.return_value.publish.call_args.args[0].twist.linear
        self.assertEqual((forward.x, forward.y, forward.z), (2.0, 0.0, 0.0))

        # 같은 배치에서 포커스가 돌아와도 일단 중립을 발행해야 합니다.
        update(SimpleNamespace(type=X.FocusOut, detail=X.NotifyNonlinear))
        self.assertEqual(publisher.return_value.publish.call_args.args[0].twist, TwistStamped().twist)
        connection.query_keymap.return_value[25 // 8] = 1 << (25 % 8)
        update()  # 포커스 복귀 시 이미 누른 W를 감지합니다.
        update(key(X.KeyRelease, 25, 30), key(X.KeyPress, 25, 30))  # W 자동 반복
        self.assertEqual(publisher.return_value.publish.call_args.args[0].twist, TwistStamped().twist)
        update(key(X.KeyRelease, 25, 40), key(X.KeyPress, 25, 41))
        self.assertEqual(publisher.return_value.publish.call_args.args[0].twist.linear.x, 2.0)

        update(key(X.KeyPress, 33, 50))
        node.check_arm()
        update(key(X.KeyRelease, 33, 60), key(X.KeyPress, 33, 60))
        client.return_value.call_async.assert_called_once()
        update(key(X.KeyRelease, 33, 70), key(X.KeyPress, 33, 71), key(X.KeyRelease, 33, 72))
        self.assertEqual(client.return_value.call_async.call_count, 2)
