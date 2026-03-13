#!/usr/bin/env python3

# heading 회전 계산에 사용한다.
import math

# ROS 2 통신용 기본 라이브러리
import rclpy
# 키보드 teleop 노드가 보내는 속도 명령
from geometry_msgs.msg import Twist
# PX4에 직접 보내는 offboard 제어용 메시지들
from px4_msgs.msg import OffboardControlMode, TrajectorySetpoint, VehicleCommand, VehicleLocalPosition, VehicleStatus
from rclpy.node import Node
from rclpy.qos import DurabilityPolicy, HistoryPolicy, QoSProfile, ReliabilityPolicy
# teleop 노드가 "지금 조종 중인지" 알려주는 플래그 메시지
from std_msgs.msg import Bool


class CmdVelPx4Bridge(Node):
    """Convert cmd_vel teleop commands into PX4 offboard velocity commands."""

    def __init__(self) -> None:
        # ROS 2 노드 이름을 등록한다.
        super().__init__('cmd_vel_px4_bridge')

        # launch 파일이나 명령행에서 바꿀 수 있는 설정값들이다.
        # timer_period_s: 브리지 루프 실행 주기
        # warmup_setpoints: offboard 진입 전에 미리 보낼 setpoint 개수
        # cmd_vel_timeout_s: 최근 명령이 너무 오래되면 정지로 판단하는 시간
        # target_system / target_component: PX4 대상 ID
        # arm_on_activate: teleop가 켜질 때 자동 arm 할지 여부
        self.declare_parameter('timer_period_s', 0.05)
        self.declare_parameter('warmup_setpoints', 10)
        self.declare_parameter('cmd_vel_timeout_s', 0.5)
        self.declare_parameter('target_system', 1)
        self.declare_parameter('target_component', 1)
        self.declare_parameter('arm_on_activate', True)

        # 파라미터 값을 실제 파이썬 변수에 저장한다.
        timer_period = self.get_parameter('timer_period_s').get_parameter_value().double_value
        self.warmup_setpoints = self.get_parameter('warmup_setpoints').get_parameter_value().integer_value
        self.cmd_vel_timeout_s = self.get_parameter('cmd_vel_timeout_s').get_parameter_value().double_value
        self.target_system = self.get_parameter('target_system').get_parameter_value().integer_value
        self.target_component = self.get_parameter('target_component').get_parameter_value().integer_value
        self.arm_on_activate = self.get_parameter('arm_on_activate').get_parameter_value().bool_value

        # PX4 상태/제어 토픽에서 주로 쓰는 QoS 설정이다.
        qos_profile = QoSProfile(
            reliability=ReliabilityPolicy.BEST_EFFORT,
            durability=DurabilityPolicy.TRANSIENT_LOCAL,
            history=HistoryPolicy.KEEP_LAST,
            depth=1,
        )

        # PX4 쪽으로 보내는 publisher 3개를 만든다.
        # 1) OffboardControlMode: 지금 어떤 방식(velocity 제어)으로 조종할지
        # 2) TrajectorySetpoint: 실제 목표 속도 / yaw rate
        # 3) VehicleCommand: offboard 모드 전환, arm 같은 명령
        self.offboard_control_mode_publisher = self.create_publisher(
            OffboardControlMode,
            '/fmu/in/offboard_control_mode',
            qos_profile,
        )
        self.trajectory_setpoint_publisher = self.create_publisher(
            TrajectorySetpoint,
            '/fmu/in/trajectory_setpoint',
            qos_profile,
        )
        self.vehicle_command_publisher = self.create_publisher(
            VehicleCommand,
            '/fmu/in/vehicle_command',
            qos_profile,
        )

        # 입력과 상태를 받는 subscriber들이다.
        # cmd_vel: 키보드 노드가 보내는 속도 명령
        # /teleop/active: 키보드 조종이 활성화되었는지 여부
        # /fmu/out/...: PX4 현재 상태와 자세 정보
        #
        # 이 환경에서는 VehicleStatus가 /fmu/out/vehicle_status 가 아니라
        # /fmu/out/vehicle_status_v1 으로 게시된다.
        # 따라서 실제 상태(nav_state, arming_state)를 읽으려면 _v1 토픽을 구독해야 한다.
        self.create_subscription(Twist, 'cmd_vel', self.cmd_vel_callback, 10)
        self.create_subscription(Bool, '/teleop/active', self.teleop_active_callback, 10)
        self.create_subscription(
            VehicleLocalPosition,
            '/fmu/out/vehicle_local_position',
            self.vehicle_local_position_callback,
            qos_profile,
        )
        self.create_subscription(
            VehicleStatus,
            '/fmu/out/vehicle_status_v1',
            self.vehicle_status_callback,
            qos_profile,
        )

        # 최근에 받은 teleop 명령과 PX4 상태를 저장해 두는 변수들이다.
        # vehicle_status / vehicle_local_position 은 subscriber callback에서 계속 갱신된다.
        self.latest_cmd_vel = Twist()
        self.last_cmd_vel_time = None
        self.teleop_active = False
        self.offboard_setpoint_counter = 0
        self.last_mode_request_us = 0
        self.last_arm_request_us = 0
        self.vehicle_status = VehicleStatus()
        self.vehicle_local_position = VehicleLocalPosition()
        # 상태 변화가 있을 때만 로그를 남기기 위한 이전 값 저장용 변수다.
        self.last_logged_nav_state = None
        self.last_logged_arming_state = None

        # timer_period마다 timer_callback을 실행한다.
        # 이 함수가 사실상 브리지 노드의 메인 루프다.
        self.timer = self.create_timer(timer_period, self.timer_callback)
        self.get_logger().info('cmd_vel -> PX4 bridge started')

    def cmd_vel_callback(self, msg: Twist) -> None:
        # 가장 최근에 받은 속도 명령을 저장해 둔다.
        # timer_callback은 이 값을 꺼내 PX4 velocity setpoint로 바꿔서 보낸다.
        self.latest_cmd_vel = msg
        self.last_cmd_vel_time = self.get_clock().now()

    def teleop_active_callback(self, msg: Bool) -> None:
        # teleop 활성화 상태가 바뀌는 순간을 감지한다.
        was_active = self.teleop_active
        self.teleop_active = msg.data

        if self.teleop_active and not was_active:
            # 새로 teleop가 켜졌다면 warmup 카운터를 다시 시작한다.
            # PX4는 offboard 모드 진입 전에 setpoint가 먼저 들어와야 한다.
            self.offboard_setpoint_counter = 0
            self.get_logger().info('Teleop activated')
        elif not self.teleop_active and was_active:
            # teleop가 꺼지면 이후에는 0 속도 setpoint를 보내서 정지/호버 쪽으로 유지한다.
            self.get_logger().info('Teleop deactivated, commanding zero velocity')

    def vehicle_local_position_callback(self, msg: VehicleLocalPosition) -> None:
        # 현재 위치와 heading 정보를 저장한다.
        # heading은 body-frame 속도를 NED frame으로 회전할 때 사용한다.
        self.vehicle_local_position = msg

    def vehicle_status_callback(self, msg: VehicleStatus) -> None:
        # 현재 PX4 nav_state, arming_state를 저장한다.
        self.vehicle_status = msg

        # 상태가 실제로 어떻게 바뀌는지 보기 위해 변화가 있을 때만 로그를 남긴다.
        # 숫자 의미 예시:
        # nav_state=14 -> OFFBOARD
        # arming_state=1 -> DISARMED
        # arming_state=2 -> ARMED
        if msg.nav_state != self.last_logged_nav_state:
            self.last_logged_nav_state = msg.nav_state
            self.get_logger().info(f'PX4 nav_state updated to {msg.nav_state}')

        if msg.arming_state != self.last_logged_arming_state:
            self.last_logged_arming_state = msg.arming_state
            self.get_logger().info(f'PX4 arming_state updated to {msg.arming_state}')

    def timer_callback(self) -> None:
        # teleop가 켜져 있는지 확인한다.
        active_control = self.teleop_active

        # PX4는 offboard 제어 중 heartbeat 성격의 메시지를 계속 받아야 한다.
        # 그래서 timer가 돌 때마다 mode와 setpoint를 반복해서 보낸다.
        self.publish_offboard_control_mode()
        self.publish_velocity_setpoint(active_control)

        # teleop가 꺼져 있으면 0 속도 setpoint만 보내고, offboard/arm 요청은 하지 않는다.
        if not active_control:
            return

        # offboard 진입 전에 준비용 setpoint를 몇 번 먼저 보낸다.
        if self.offboard_setpoint_counter < self.warmup_setpoints:
            self.offboard_setpoint_counter += 1
            return

        now_us = self.now_us()

        # 아직 offboard 모드가 아니라면 1초 간격으로 전환 명령을 보낸다.
        # 반대로, 이미 nav_state가 OFFBOARD라면 이 블록은 실행되지 않는다.
        if self.vehicle_status.nav_state != VehicleStatus.NAVIGATION_STATE_OFFBOARD:
            if now_us - self.last_mode_request_us > 1_000_000:
                self.publish_vehicle_command(
                    VehicleCommand.VEHICLE_CMD_DO_SET_MODE,
                    # PX4에서 offboard 모드를 요청할 때 사용하는 값
                    param1=1.0,
                    param2=6.0,
                )
                self.last_mode_request_us = now_us
                self.get_logger().info(
                    'Requested PX4 offboard mode '
                    f'(current nav_state={self.vehicle_status.nav_state}, '
                    f'arming_state={self.vehicle_status.arming_state})'
                )

        # 필요하면 자동 arm도 수행한다.
        # 즉, offboard는 이미 들어가 있었지만 아직 disarmed 상태라면
        # arm만 따로 요청하는 상황도 가능하다.
        if self.arm_on_activate and self.vehicle_status.arming_state != VehicleStatus.ARMING_STATE_ARMED:
            if now_us - self.last_arm_request_us > 1_000_000:
                self.publish_vehicle_command(
                    VehicleCommand.VEHICLE_CMD_COMPONENT_ARM_DISARM,
                    # 1.0 은 arm, 0.0 은 disarm
                    param1=1.0,
                )
                self.last_arm_request_us = now_us
                self.get_logger().info(
                    'Requested arm command '
                    f'(current nav_state={self.vehicle_status.nav_state}, '
                    f'arming_state={self.vehicle_status.arming_state})'
                )

    def publish_offboard_control_mode(self) -> None:
        # 이 노드는 "position 제어"가 아니라 "velocity 제어"를 사용한다.
        # 이 메시지는 PX4가 offboard 상태를 유지하는 heartbeat 역할도 한다.
        msg = OffboardControlMode()
        msg.position = False
        msg.velocity = True
        msg.acceleration = False
        msg.attitude = False
        msg.body_rate = False
        msg.timestamp = self.now_us()
        self.offboard_control_mode_publisher.publish(msg)

    def publish_velocity_setpoint(self, active_control: bool) -> None:
        # PX4 TrajectorySetpoint 메시지를 만든다.
        msg = TrajectorySetpoint()
        nan = float('nan')

        # 이 노드는 위치/가속도/jerk는 직접 제어하지 않는다.
        # PX4에서는 "이 축은 내가 제어하지 않음"을 NaN으로 표현한다.
        msg.position = [nan, nan, nan]
        msg.acceleration = [nan, nan, nan]
        msg.jerk = [nan, nan, nan]

        # teleop가 켜져 있으면 최근 cmd_vel을 사용하고,
        # 꺼져 있으면 0 속도를 보내 정지 상태를 유지한다.
        # 즉, 키 입력이 없을 때는 이전 속도를 유지하지 않고 안전하게 멈추는 쪽을 선택한다.
        velocity_ned = self.current_velocity_setpoint_ned() if active_control else [0.0, 0.0, 0.0]
        yaw_rate = self.current_yaw_rate() if active_control else 0.0

        msg.velocity = velocity_ned
        # yaw 자체는 현재 기체 heading을 유지하고,
        # 회전 명령은 yawspeed로만 준다.
        msg.yaw = self.current_heading_or_zero()
        msg.yawspeed = yaw_rate
        msg.timestamp = self.now_us()
        self.trajectory_setpoint_publisher.publish(msg)

    def current_velocity_setpoint_ned(self) -> list[float]:
        # 아직 cmd_vel을 한 번도 받은 적이 없으면 정지 명령을 사용한다.
        if self.last_cmd_vel_time is None:
            return [0.0, 0.0, 0.0]

        # 마지막 키 입력이 너무 오래됐으면 위험하므로 정지시킨다.
        age = (self.get_clock().now() - self.last_cmd_vel_time).nanoseconds / 1e9
        if age > self.cmd_vel_timeout_s:
            return [0.0, 0.0, 0.0]

        # keyboard teleop가 보내는 값을 body 기준 속도로 해석한다.
        # body_forward: 기체 앞쪽
        # body_right:   기체 오른쪽
        # body_down:    기체 아래쪽(NED 기준 +z)
        body_forward = float(self.latest_cmd_vel.linear.x)
        body_right = float(self.latest_cmd_vel.linear.y)
        body_down = float(self.latest_cmd_vel.linear.z)

        # PX4 TrajectorySetpoint.velocity는 NED 좌표계로 보내야 한다.
        # 따라서 기체 기준(body-frame) 속도를 현재 heading으로 회전시켜
        # 북(North), 동(East), 하(Down) 속도로 바꾼다.
        # 이 변환 덕분에 사용자는 기체 기준 앞/뒤/좌/우로 조종하고,
        # PX4에는 세계 좌표 기준 속도가 전달된다.
        heading = self.current_heading_or_zero()
        north = math.cos(heading) * body_forward - math.sin(heading) * body_right
        east = math.sin(heading) * body_forward + math.cos(heading) * body_right
        down = body_down
        return [north, east, down]

    def current_yaw_rate(self) -> float:
        # yaw 회전도 timeout을 동일하게 적용한다.
        if self.last_cmd_vel_time is None:
            return 0.0

        age = (self.get_clock().now() - self.last_cmd_vel_time).nanoseconds / 1e9
        if age > self.cmd_vel_timeout_s:
            return 0.0

        return float(self.latest_cmd_vel.angular.z)

    def current_heading_or_zero(self) -> float:
        # heading이 정상 숫자라면 사용하고, 아니면 0.0을 기본값으로 사용한다.
        # heading 정보가 없으면 body->NED 변환 정확도는 떨어지지만 코드는 계속 동작할 수 있다.
        heading = float(self.vehicle_local_position.heading)
        if math.isfinite(heading):
            return heading
        return 0.0

    def publish_vehicle_command(self, command: int, **params: float) -> None:
        # PX4 명령 메시지를 만들어 모드 전환, arm 같은 명령을 보낸다.
        msg = VehicleCommand()
        msg.command = command
        msg.param1 = params.get('param1', 0.0)
        msg.param2 = params.get('param2', 0.0)
        msg.param3 = params.get('param3', 0.0)
        msg.param4 = params.get('param4', 0.0)
        msg.param5 = params.get('param5', 0.0)
        msg.param6 = params.get('param6', 0.0)
        msg.param7 = params.get('param7', 0.0)
        msg.target_system = self.target_system
        msg.target_component = self.target_component
        msg.source_system = self.target_system
        msg.source_component = self.target_component
        msg.from_external = True
        msg.timestamp = self.now_us()
        self.vehicle_command_publisher.publish(msg)

    def now_us(self) -> int:
        # PX4 메시지는 보통 마이크로초(us) 단위 timestamp를 사용한다.
        return int(self.get_clock().now().nanoseconds / 1000)


def main(args=None) -> None:
    # ROS 2 통신 시작
    rclpy.init(args=args)
    node = CmdVelPx4Bridge()

    try:
        # subscriber와 timer 콜백을 계속 실행한다.
        rclpy.spin(node)
    finally:
        # 종료 시 ROS 자원을 정리한다.
        node.destroy_node()
        rclpy.shutdown()


if __name__ == '__main__':
    main()
