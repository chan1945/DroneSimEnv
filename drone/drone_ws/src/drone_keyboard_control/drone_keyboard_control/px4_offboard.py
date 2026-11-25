# 키보드 조종 명령을 PX4 Offboard 모드와 NED 목표값으로 전달하는 ROS 2 노드다.
import math
from time import monotonic

import rclpy
from geometry_msgs.msg import TwistStamped
from px4_msgs.msg import (
    OffboardControlMode, TrajectorySetpoint, VehicleCommand, VehicleCommandAck,
    VehicleLandDetected, VehicleLocalPosition, VehicleStatus,
)
from rclpy.callback_groups import ReentrantCallbackGroup
from rclpy.executors import ExternalShutdownException
from rclpy.node import Node
from rclpy.qos import qos_profile_sensor_data
from rclpy.task import Future
from std_srvs.srv import Trigger

from .flight_control import FlightController

# 모든 축에서 속도가 0인 기수 기준 명령이다.
NEUTRAL = (0.0, 0.0, 0.0, 0.0)
# MAV_COMP_ID_ONBOARD_COMPUTER를 보내서 해당 명령에 대한 응답만 받는다.
SOURCE_COMPONENT = 191
# 입력이 끊기면 마지막 이동 명령을 무효화할 시간(초)이다.
INPUT_TIMEOUT = 0.25


class Px4Offboard(Node):
    """시동 서비스와 20 Hz 제어 루프를 같은 executor 스레드에서 처리한다."""

    def __init__(self):
        """상태를 중립으로 초기화하고 PX4 및 조종 인터페이스를 연결한다."""
        super().__init__('px4_offboard')
        # 입력 명령과 마지막 수신 시각을 함께 보관한다.
        self.command = NEUTRAL
        self.input_at = -math.inf
        # 상태, 위치 및 지상 여부는 PX4에서 독립된 주기로 들어온다.
        self.status = None
        self.local = None
        self.landed = False
        # 단조 시각으로 상태 및 추정값의 유효 기간을 검사한다.
        self.status_at = self.local_at = self.landed_at = -math.inf
        # 연속 heartbeat 시작과 마지막 발행 시각으로 사전 송신 구간을 확인한다.
        self.stream_since = self.last_heartbeat = -math.inf
        # 시동 요청 한 건의 결과, 단계별 확인 명령 및 제한 시간을 추적한다.
        self.pending = None
        self.waiting_command = None
        self.deadline = -math.inf
        # 이 노드가 시동을 확인한 뒤에만 조종 명령을 허용한다.
        self.active = False
        # 지상에서 새 상승 입력이 있기 전까지 수직 목표 속도를 0으로 유지한다.
        self.await_liftoff = True
        # 축별 위치 및 방위각 목표를 관리하는 계산기다.
        self.control = FlightController()
        # heartbeat, 궤적 및 일회성 모드/시동 명령을 전송하는 발행자다.
        self.mode_pub = self.create_publisher(OffboardControlMode, '/fmu/in/offboard_control_mode', 1)
        self.trajectory_pub = self.create_publisher(TrajectorySetpoint, '/fmu/in/trajectory_setpoint', 1)
        self.vehicle_pub = self.create_publisher(VehicleCommand, '/fmu/in/vehicle_command', 1)
        # PX4 v1.16.2의 VehicleStatus만 버전 접미사를 사용한다.
        self.create_subscription(VehicleStatus, '/fmu/out/vehicle_status_v1', self.on_status, qos_profile_sensor_data)
        self.create_subscription(VehicleLocalPosition, '/fmu/out/vehicle_local_position', self.on_local, qos_profile_sensor_data)
        self.create_subscription(VehicleLandDetected, '/fmu/out/vehicle_land_detected', self.on_landed, qos_profile_sensor_data)
        self.create_subscription(VehicleCommandAck, '/fmu/out/vehicle_command_ack', self.on_ack, qos_profile_sensor_data)
        self.create_subscription(TwistStamped, 'teleop/cmd_vel', self.on_input, 1)
        # 별도 그룹의 시동 코루틴이 Future를 기다리는 동안 구독과 타이머가 계속 돈다.
        self.create_service(Trigger, 'teleop/arm', self.on_arm, callback_group=ReentrantCallbackGroup())
        self.create_timer(0.05, self.tick)

    def on_status(self, msg):
        """msg에 포함된 실제 PX4 모드와 시동 상태로 현재 조종권을 확인한다."""
        self.status, self.status_at = msg, monotonic()
        if msg.failsafe or (self.active and not (self.is_armed() and self.is_offboard())):
            self.relinquish('PX4 비행 상태가 변경되었습니다.')

    def on_local(self, msg):
        """msg의 위치·속도·방위각 유효성을 검사하고 추정기 재설정을 처리한다."""
        # 위치, 속도, 방위각을 모두 사용하는 제어기가 받아들일 수 있는 측정값이다.
        observed = (msg.x, msg.y, msg.z, msg.vx, msg.vy, msg.vz, msg.heading)
        # heading_good_for_control은 지자기 사용 시 비행 중 최종 정렬 후 켜진다.
        # 지상 시동에는 유효한 로컬 추정과 유한한 방위각을 쓰고 PX4의 시동 검사를 따른다.
        if not (msg.xy_valid and msg.z_valid and msg.v_xy_valid and msg.v_z_valid
                and all(map(math.isfinite, observed))):
            self.local = None
            self.relinquish('PX4 위치 또는 방위각 추정이 유효하지 않습니다.')
            return
        # 좌표 원점이나 기수가 재설정되면 새 좌표계에서 현재 위치부터 유지한다.
        previous = self.local
        if previous is None or (msg.xy_reset_counter, msg.z_reset_counter, msg.heading_reset_counter) != (
            previous.xy_reset_counter, previous.z_reset_counter, previous.heading_reset_counter
        ):
            self.control.reset((msg.x, msg.y, msg.z), msg.heading)
        self.local, self.local_at = msg, monotonic()

    def on_landed(self, msg):
        """msg의 지상 판정과 수신 시각을 보관한다."""
        self.landed, self.landed_at = msg.landed, monotonic()

    def on_input(self, msg):
        """msg의 좌표계, 수치, 발생 시각을 검증한 뒤 최신 속도 한 건만 저장한다."""
        # 앞·왼쪽·위 선속도와 반시계 방향 각속도를 읽는다.
        linear, angular = msg.twist.linear, msg.twist.angular
        values = (linear.x, linear.y, linear.z, angular.z)
        # 전송 큐에 오래 머문 명령도 통신이 끊긴 경우와 같이 처리한다.
        stamp = msg.header.stamp
        age = self.get_clock().now().nanoseconds * 1e-9 - (stamp.sec + stamp.nanosec * 1e-9)
        if (msg.header.frame_id != 'base_footprint' or not all(map(math.isfinite, values))
                or not -0.05 <= age <= INPUT_TIMEOUT or angular.x != 0.0 or angular.y != 0.0
                or math.hypot(*values[:3]) > 2.000001 or abs(angular.z) > math.pi / 4 + 1e-6):
            self.command, self.input_at = NEUTRAL, -math.inf
            return
        self.command, self.input_at = values, monotonic()

    def is_armed(self):
        """마지막 VehicleStatus가 실제 시동 완료를 나타내는지 반환한다."""
        return self.status is not None and self.status.arming_state == VehicleStatus.ARMING_STATE_ARMED

    def is_offboard(self):
        """마지막 VehicleStatus가 Offboard 모드인지 반환한다."""
        return self.status is not None and self.status.nav_state == VehicleStatus.NAVIGATION_STATE_OFFBOARD

    def finish(self, success, message):
        """success와 message를 대기 중인 서비스에 전달하고 다음 요청을 허용한다."""
        if self.pending is not None:
            self.pending.set_result((success, message))
            self.pending = None
            self.waiting_command = None

    def relinquish(self, message):
        """message를 대기 중인 서비스에 전달하고 마지막 조종 명령을 폐기한다."""
        if self.active:
            self.get_logger().warning(message)
        self.active = False
        self.await_liftoff = True
        self.command, self.input_at = NEUTRAL, -math.inf
        self.stream_since = self.last_heartbeat = -math.inf
        self.finish(False, message)

    def on_ack(self, msg):
        """msg가 이 노드에서 보낸 현재 단계의 명령을 거부하면 요청을 종료한다."""
        if (self.pending is None or msg.command != self.waiting_command
                or msg.target_component != SOURCE_COMPONENT or msg.target_system != self.status.system_id):
            return
        if msg.result not in (VehicleCommandAck.VEHICLE_CMD_RESULT_ACCEPTED,
                              VehicleCommandAck.VEHICLE_CMD_RESULT_IN_PROGRESS):
            self.finish(False, f'PX4 명령 {msg.command} 거부 (결과 {msg.result}, 사유 {msg.result_param1}).')

    def ready_to_arm(self, now):
        """now 기준의 위치·지상·중립 입력으로 시동을 거부할 이유를 반환한다."""
        if (self.status is None or self.local is None or self.status.failsafe
                or now - self.status_at > 2.0 or now - self.local_at > 0.5):
            return 'PX4 상태 및 유효한 위치 추정을 기다리십시오.'
        if now - self.landed_at > 2.5 or not self.landed:
            return 'PX4의 지상 판정이 필요합니다.'
        if now - self.input_at > INPUT_TIMEOUT or self.command != NEUTRAL:
            return '조종 창에서 이동 키를 모두 놓은 뒤 P를 누르십시오.'
        return ''

    async def on_arm(self, request, response):
        """빈 request로 시작한 시동 절차의 실제 PX4 확인 결과를 response에 기록한다."""
        # 시동 자격과 동시 요청을 검사하는 단조 시각이다.
        now = monotonic()
        if self.pending is not None:
            response.message = '다른 시동 요청을 처리 중입니다.'
        elif self.is_armed():
            response.success = self.active and self.is_offboard()
            response.message = '이미 시동 중입니다.'
        else:
            response.message = self.ready_to_arm(now)
            if not response.message:
                # 타이머가 이 future를 완료할 때까지 콜백 실행권을 반환한다.
                self.pending = Future(executor=self.executor)
                self.deadline = now + 5.0
                response.success, response.message = await self.pending
        return response

    def send_vehicle_command(self, command, param1, param2=0.0):
        """command와 두 PX4 매개변수 param1, param2를 현재 기체로 한 번 보낸다."""
        # 대상은 수신한 상태의 기체이며 응답을 식별하도록 송신 컴포넌트를 지정한다.
        msg = VehicleCommand()
        msg.timestamp = self.get_clock().now().nanoseconds // 1000
        msg.command, msg.param1, msg.param2 = command, param1, param2
        msg.target_system, msg.target_component = self.status.system_id, self.status.component_id
        msg.source_system, msg.source_component = self.status.system_id, SOURCE_COMPONENT
        msg.from_external = True
        self.waiting_command = command
        self.deadline = monotonic() + 5.0
        self.vehicle_pub.publish(msg)

    def advance_arm(self, now):
        """now에 중립·지상·연속 heartbeat를 검사한 뒤 각 명령을 순서대로 진행한다."""
        # 진행 중에도 조종 입력, 지상 상태, PX4의 실제 모드를 매 주기 재검사한다.
        refusal = self.ready_to_arm(now)
        if refusal:
            self.finish(False, refusal)
        elif now >= self.deadline:
            self.finish(False, 'PX4 시동 절차 확인 시간이 초과되었습니다.')
        elif self.waiting_command == VehicleCommand.VEHICLE_CMD_COMPONENT_ARM_DISARM:
            if not self.is_offboard():
                self.finish(False, '시동 확인 중 PX4가 Offboard 모드를 벗어났습니다.')
            elif self.is_armed():
                self.active = True
                self.await_liftoff = True
                self.control.reset((self.local.x, self.local.y, self.local.z), self.local.heading)
                self.finish(True, 'Offboard 시동 완료. Shift를 눌러 이륙하십시오.')
        elif now - self.stream_since >= 1.1:
            if self.is_offboard():
                self.send_vehicle_command(VehicleCommand.VEHICLE_CMD_COMPONENT_ARM_DISARM, 1.0)
            elif self.waiting_command is None:
                # PX4 custom mode 6은 Offboard이며 param1의 1은 custom mode 활성화다.
                self.send_vehicle_command(VehicleCommand.VEHICLE_CMD_DO_SET_MODE, 1.0, 6.0)

    def tick(self):
        """측정과 입력의 신선도를 검사하고 20 Hz로 heartbeat와 목표값을 갱신한다."""
        # 단조 시각으로 감속, 타임아웃과 사전 송신 연속성을 계산한다.
        now = monotonic()
        if (self.local is None or self.status is None or self.status.failsafe
                or now - self.local_at > 0.5 or now - self.status_at > 2.0):
            self.relinquish('PX4 상태 또는 위치 추정 연결이 끊겼습니다.')
            return
        # 외부에서 시동한 기체나 조종권을 잃은 기체에는 heartbeat도 보내지 않는다.
        if self.is_armed() and not (self.active or self.pending):
            return
        if now - self.last_heartbeat >= 0.5:
            self.stream_since = now
        self.last_heartbeat = now
        if self.pending is not None:
            self.advance_arm(now)
        # 최신 입력과 실제 측정 NED 좌표로 유지 또는 이동 목표를 계산한다.
        command = self.command if self.active and now - self.input_at <= INPUT_TIMEOUT else NEUTRAL
        if self.active and command[2] > 0.0:
            self.await_liftoff = False
        # 지상에서 시동만 걸었을 때 추정 고도의 미세한 흔들림이 이륙 요청이 되는 것을 막는다.
        grounded = self.await_liftoff
        local = self.local
        position = (local.x, local.y, local.z)
        if grounded:
            self.control.reset(position, local.heading)
            command = NEUTRAL
        # 제어기 출력에는 위치 제어 축과 속도 제어 축이 따로 표시된다.
        target = self.control.step(now, position, (local.vx, local.vy, local.vz), local.heading, command)
        # PX4 메시지 시각은 ROS 시스템 시각을 마이크로초로 변환한다.
        timestamp = self.get_clock().now().nanoseconds // 1000
        mode = OffboardControlMode()
        mode.timestamp = timestamp
        mode.position = target.position_control
        mode.velocity = not mode.position
        self.mode_pub.publish(mode)
        if not self.is_offboard() or not (self.active or self.pending):
            return
        # 접지 대기 중에는 z 위치를 비워 수직 속도 0만 지시한다.
        trajectory = TrajectorySetpoint()
        trajectory.timestamp = timestamp
        trajectory.position = list(target.position)
        trajectory.velocity = list(target.velocity)
        if grounded:
            trajectory.position[2] = math.nan
            trajectory.velocity[2] = 0.0
        trajectory.acceleration = [math.nan] * 3
        trajectory.jerk = [math.nan] * 3
        trajectory.yaw, trajectory.yawspeed = target.yaw, target.yawspeed
        self.trajectory_pub.publish(trajectory)


def main(args=None):
    """args로 ROS를 초기화하고 제어 노드를 종료 신호까지 실행한다."""
    rclpy.init(args=args)
    # 단일 스레드 executor가 모든 상태 변경을 직렬화한다.
    node = Px4Offboard()
    try:
        rclpy.spin(node)
    except (KeyboardInterrupt, ExternalShutdownException):
        pass
    finally:
        node.destroy_node()
        rclpy.try_shutdown()
