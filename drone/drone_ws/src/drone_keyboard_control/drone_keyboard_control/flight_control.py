# 기수 기준 조종 명령을 PX4의 북·동·하향 목표값으로 바꾸고 정지한 위치를 유지한다.
"""ROS와 독립적으로 수평·수직 제동 및 기수 방향 제어를 계산한다."""

from dataclasses import dataclass
import math


# NED 좌표계에서 북·동·하향 순서로 값을 전달하는 벡터 형식이다.
Vector3 = tuple[float, float, float]


@dataclass(frozen=True)
class Setpoint:
    """PX4에 한 번에 발행할 위치·속도·기수 목표와 제어 모드를 담는다."""

    position: Vector3  # NED 위치(m)이며 속도 제어에 맡길 축은 NaN이다.
    velocity: Vector3  # NED 속도(m/s)이며 위치를 유지하는 축은 NaN이다.
    yaw: float  # 북쪽에서 시계 방향으로 잰 절대 목표 방위각(rad)이다.
    yawspeed: float  # 방위각 제어기가 함께 사용할 시계 방향 회전 속도(rad/s)다.
    position_control: bool  # 한 축이라도 위치를 유지하면 PX4의 위치 제어 플래그를 켠다.


class _PositionHold:
    """함께 움직이는 축 그룹(XY 또는 Z)의 정지 판정과 고정 목표를 보관한다."""

    def __init__(self):
        """초기 위치를 받을 때까지 해당 축의 고정 목표를 비워 둔다."""
        self.target = None  # 정지 시점에 한 번 저장하는 해당 축의 좌표 튜플이다.
        self.still_since = None  # 속도가 연속으로 정지 임계값 이내에 든 첫 시각이다.

    def update(self, moving, speed, coordinates, now):
        """moving은 입력 유무, speed는 실측 속력, coordinates는 현 좌표, now는 초 단위 시각이다."""
        if moving:
            self.target = None
            self.still_since = None
        elif self.target is None:
            if speed > 0.1:
                self.still_since = None
            elif self.still_since is None:
                self.still_since = now
            elif now - self.still_since >= 0.2:
                self.target = coordinates
        return self.target


class FlightController:
    """매 제어 주기에 실제 방위각을 따라 이동하고 수평·수직을 독립적으로 제동한다."""

    def __init__(self):
        """첫 유효 추정치를 받으면 현재 위치와 기수를 초기 유지 목표로 삼는다."""
        self._horizontal = _PositionHold()  # 북·동축을 한 쌍으로 전환한다.
        self._vertical = _PositionHold()  # 고도는 수평 조작과 독립적으로 고정한다.
        self._yaw = None  # 마지막 목표 방위각을 기억해 회전 입력이 없을 때 유지한다.
        self._turning = False  # 회전 키가 해제된 첫 표본을 구별한다.
        self._previous_time = None  # 연속 두 호출의 시간차로 회전량을 계산한다.

    def reset(self, position: Vector3, heading: float):
        """NED position(m)과 현재 heading(rad)을 새 세션의 고정 목표로 사용한다."""
        if not all(map(math.isfinite, (*position, heading))):
            raise ValueError("초기 위치와 방위각은 유한해야 합니다.")
        self._horizontal.target = tuple(position[:2])
        self._vertical.target = (position[2],)
        self._horizontal.still_since = self._vertical.still_since = None
        self._yaw = heading
        self._turning = False
        self._previous_time = None

    def step(self, now: float, position: Vector3, velocity: Vector3,
             heading: float, command: tuple[float, float, float, float]) -> Setpoint:
        """now(초), 실측 NED position·velocity, heading(rad), 앞·왼쪽·위·좌회전 command로 목표를 계산한다."""
        if not all(map(math.isfinite, (now, *position, *velocity, heading, *command))):
            raise ValueError("제어 입력과 위치 추정치는 유한해야 합니다.")
        if self._yaw is None:
            self.reset(position, heading)

        # forward, left, up은 기수 수평 좌표계 선속도, ccw는 위에서 본 반시계 회전 속도다.
        forward, left, up, ccw = command
        # xy_hold와 z_hold는 정지한 축의 저장 좌표이며, 이동·감속 중에는 None이다.
        xy_hold = self._horizontal.update(
            forward != 0.0 or left != 0.0, math.hypot(*velocity[:2]), tuple(position[:2]), now)
        z_hold = self._vertical.update(up != 0.0, abs(velocity[2]), (position[2],), now)

        # north와 east는 기체 기울기를 제외하고 현재 기수 방향만 반영한 지표면 속도다.
        north = math.cos(heading) * forward + math.sin(heading) * left
        east = math.sin(heading) * forward - math.cos(heading) * left
        # px, py, pz와 vx, vy, vz 중 같은 축의 한 목표만 유효하게 전달한다.
        px, py = xy_hold if xy_hold is not None else (math.nan, math.nan)
        pz = z_hold[0] if z_hold is not None else math.nan
        vx, vy = (math.nan, math.nan) if xy_hold is not None else (north, east)
        vz = math.nan if z_hold is not None else -up

        # elapsed는 이번 주기에 적분할 초 단위 시간이며 초기화 직후에는 0이다.
        elapsed = 0.0 if self._previous_time is None else max(0.0, now - self._previous_time)
        self._previous_time = now
        if ccw:
            if not self._turning:
                self._yaw = heading
            self._yaw = math.remainder(self._yaw - ccw * elapsed, math.tau)
        elif self._turning:
            self._yaw = heading
        self._turning = ccw != 0.0

        return Setpoint((px, py, pz), (vx, vy, vz), self._yaw, -ccw,
                        xy_hold is not None or z_hold is not None)
