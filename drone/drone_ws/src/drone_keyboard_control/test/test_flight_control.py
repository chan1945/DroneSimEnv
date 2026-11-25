# 시뮬레이터 없이 기수 좌표 변환, 분리된 축 제동, 방위각 유지 동작을 검증한다.
"""기수 방향이 바뀌거나 조종 키를 일부만 놓는 경우를 재현한다."""

import math
import unittest

from drone_keyboard_control.flight_control import FlightController


class FlightControlTests(unittest.TestCase):
    """알려진 위치·속도 표본을 순서대로 주어 PX4 목표값을 확인한다."""

    def setUp(self):
        """각 사례를 지상 원점에서 기수가 북쪽을 향한 상태로 시작한다."""
        self.control = FlightController()  # 시간에 따른 위치·방위각 목표를 보관한다.
        self.origin = (0.0, 0.0, 0.0)  # 초기 위치 및 정지 속도의 세 NED 성분이다.
        self.neutral = (0.0, 0.0, 0.0, 0.0)  # 모든 키를 놓은 상태의 조종 명령이다.
        self.control.reset(self.origin, 0.0)

    def test_ground_and_yaw_only_keep_initial_position(self):
        """지상에서 시동 및 제자리 회전 시 의도하지 않은 위치 이동을 막는다."""
        # hold는 현재 위치 표본이 이동해도 최초 지상 목표를 유지해야 한다.
        hold = self.control.step(1.0, (1.0, 2.0, 0.0), self.origin, 0.0, self.neutral)
        self.assertEqual(hold.position, self.origin)
        self.assertTrue(all(map(math.isnan, hold.velocity)))
        self.assertTrue(hold.position_control)
        # rotating은 왼쪽 회전율을 NED 부호로 바꾸고 위치는 그대로 둔다.
        rotating = self.control.step(1.05, self.origin, self.origin, 0.0,
                                     (0.0, 0.0, 0.0, math.pi / 4))
        self.assertEqual(rotating.position, self.origin)
        self.assertAlmostEqual(rotating.yawspeed, -math.pi / 4)
        self.assertAlmostEqual(rotating.yaw, -math.pi / 4 * 0.05)
        # released는 키를 뗀 실측 기수 방향, drifting은 이후 바람에 밀린 표본이다.
        released = self.control.step(1.1, self.origin, self.origin, -0.03, self.neutral)
        drifting = self.control.step(1.2, self.origin, self.origin, -0.06, self.neutral)
        self.assertEqual(released.yaw, -0.03)
        self.assertEqual(drifting.yaw, released.yaw)
        self.assertEqual(released.yawspeed, 0.0)

    def test_heading_transform_preserves_diagonal_speed(self):
        """동쪽을 향한 앞·왼쪽·상승 입력을 NED 속도 세 성분으로 변환한다."""
        # component는 3차원 대각선에서 전체 2 m/s를 만드는 한 축의 속도다.
        component = 2.0 / math.sqrt(3)
        # command는 세 축 동시 움직임과 독립적인 우회전을 요청한다.
        command = (component, component, component, -math.pi / 4)
        # east는 실제 기수가 동쪽일 때, south는 동일 키를 유지해 남쪽을 향했을 때다.
        east = self.control.step(0.0, self.origin, self.origin, math.pi / 2, command)
        south = self.control.step(0.1, self.origin, self.origin, math.pi, command)
        self.assertAlmostEqual(east.velocity[0], component)
        self.assertAlmostEqual(east.velocity[1], component)
        self.assertAlmostEqual(east.velocity[2], -component)
        self.assertAlmostEqual(math.hypot(*east.velocity), 2.0)
        self.assertAlmostEqual(south.velocity[0], -component)
        self.assertAlmostEqual(south.velocity[1], component)
        self.assertEqual(south.yawspeed, math.pi / 4)
        self.assertFalse(south.position_control)
        self.assertTrue(all(map(math.isnan, south.position)))

    def test_releasing_climb_latches_altitude_while_forward_continues(self):
        """전진 중 상승 해제 시 수직 감속이 끝난 시점의 고도를 한 번만 고정한다."""
        # forward는 수평 운동만 유지하는 명령이다.
        forward = (2.0, 0.0, 0.0, 0.0)
        self.control.step(0.0, self.origin, self.origin, 0.0,
                          (math.sqrt(2), 0.0, math.sqrt(2), 0.0))
        # braking은 수직 속도 목표가 0이고 위치 목표는 비어 있어야 한다.
        braking = self.control.step(1.0, (1.0, 0.0, -1.0), (2.0, 0.0, -0.3), 0.0, forward)
        self.assertEqual(braking.velocity, (2.0, 0.0, 0.0))
        self.assertTrue(math.isnan(braking.position[2]))
        self.control.step(1.1, (1.2, 0.0, -1.1), (2.0, 0.0, -0.05), 0.0, forward)
        # 0.1 m/s를 잠시 넘기면 연속 정지 시간이 처음부터 다시 측정되어야 한다.
        self.control.step(1.25, (1.5, 0.0, -1.2), (2.0, 0.0, -0.11), 0.0, forward)
        self.control.step(1.4, (1.8, 0.0, -1.3), (2.0, 0.0, -0.05), 0.0, forward)
        # before와 after는 재시작한 0.2초 구간의 이전·이후 표본이다.
        before = self.control.step(1.55, (2.1, 0.0, -1.31), (2.0, 0.0, -0.05), 0.0, forward)
        after = self.control.step(1.65, (2.3, 0.0, -1.32), (2.0, 0.0, 0.0), 0.0, forward)
        self.assertTrue(math.isnan(before.position[2]))
        self.assertEqual(after.position[2], -1.32)
        self.assertTrue(math.isnan(after.velocity[2]))
        self.assertEqual(after.velocity[0], 2.0)
        self.assertTrue(after.position_control)
        # moved는 이후 수직 위치가 조금 달라져도 목표 고도를 재설정하지 않는지 확인한다.
        moved = self.control.step(1.75, (2.5, 0.0, -1.5), (2.0, 0.0, -0.2), 0.0, forward)
        self.assertEqual(moved.position[2], -1.32)

    def test_releasing_forward_latches_xy_while_descending(self):
        """수평 감속과 위치 확보가 수직 하강 속도 명령과 독립적으로 진행된다."""
        # descend는 상승 축에 음수를 입력해 하강하는 명령이다.
        descend = (0.0, 0.0, -2.0, 0.0)
        self.control.step(0.0, self.origin, self.origin, 0.0, (2.0, 0.0, 0.0, 0.0))
        # rolling은 각 수평 성분은 작아도 합성 속력이 임계값보다 큰 표본이다.
        rolling = (0.09, 0.09, 2.0)
        self.control.step(1.0, self.origin, rolling, 0.0, descend)
        self.control.step(1.25, (1.0, 2.0, 1.0), rolling, 0.0, descend)
        # slow는 합성 수평 속력이 0.1 m/s 이하가 된 첫 표본이다.
        slow = self.control.step(1.4, (1.1, 2.1, 1.3), (0.01, 0.01, 2.0), 0.0, descend)
        self.assertEqual(slow.velocity, (0.0, 0.0, 2.0))
        # stopped는 확정된 XY 위치를, later는 이후 위치 변화를 포함한다.
        stopped = self.control.step(1.65, (1.2, 2.2, 1.8), (0.0, 0.0, 2.0), 0.0, descend)
        later = self.control.step(1.75, (1.5, 2.5, 2.0), (0.0, 0.0, 2.0), 0.0, descend)
        self.assertEqual(stopped.position[:2], (1.2, 2.2))
        self.assertEqual(later.position[:2], stopped.position[:2])
        self.assertTrue(all(map(math.isnan, stopped.velocity[:2])))
        self.assertEqual(stopped.velocity[2], 2.0)

    def test_reset_drops_old_targets_and_rejects_invalid_state(self):
        """재시동 시 기존 위치·방위각 대신 새 추정치를 초기 목표로 삼는다."""
        # home은 재시동 후 추정한 새 NED 위치다.
        home = (12.0, 32.0, -3.0)
        self.control.reset(home, 1.2)
        # held는 최초 입력이 중립일 때 새 위치와 방위각을 유지해야 한다.
        held = self.control.step(100.0, home, self.origin, 1.2, self.neutral)
        self.assertEqual(held.position, home)
        self.assertEqual(held.yaw, 1.2)
        with self.assertRaises(ValueError):
            self.control.step(101.0, home, self.origin, math.nan, self.neutral)
