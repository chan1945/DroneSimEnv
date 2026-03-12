#!/usr/bin/env python3

# 수학 함수(math.isfinite)를 사용해 heading 값이 정상인지 확인한다.
import math

# ROS 2 Python 클라이언트 라이브러리
import rclpy
# PX4와 ROS 2 사이에서 주고받는 메시지 타입들
from px4_msgs.msg import OffboardControlMode, TrajectorySetpoint, VehicleCommand, VehicleLocalPosition, VehicleStatus
from rclpy.node import Node
from rclpy.qos import DurabilityPolicy, HistoryPolicy, QoSProfile, ReliabilityPolicy


class OffboardModeNode(Node):
    """Keep the vehicle at its current position and request PX4 offboard mode."""

    def __init__(self) -> None:
        # ROS 2 노드 이름을 'offboard_mode_node'로 등록한다.
        super().__init__('offboard_mode_node')

        # launch 파일이나 명령행에서 값을 바꿀 수 있도록 파라미터를 선언한다.
        # timer_period_s: 타이머 주기(초)
        # warmup_setpoints: offboard 명령 전 미리 보낼 setpoint 개수
        # target_system / target_component: PX4 대상 시스템 ID
        self.declare_parameter('timer_period_s', 0.1)
        self.declare_parameter('warmup_setpoints', 10)
        self.declare_parameter('target_system', 1)
        self.declare_parameter('target_component', 1)

        # 선언한 파라미터 값을 읽어 실제 변수로 저장한다.
        timer_period = self.get_parameter('timer_period_s').get_parameter_value().double_value
        self.warmup_setpoints = self.get_parameter('warmup_setpoints').get_parameter_value().integer_value
        self.target_system = self.get_parameter('target_system').get_parameter_value().integer_value
        self.target_component = self.get_parameter('target_component').get_parameter_value().integer_value

        # PX4 uXRCE-DDS 기본 예제에서 자주 쓰는 QoS 설정이다.
        # 센서/상태 값은 가장 최신 값이 중요하므로 depth=1로 둔다.
        qos_profile = QoSProfile(
            reliability=ReliabilityPolicy.BEST_EFFORT,
            durability=DurabilityPolicy.TRANSIENT_LOCAL,
            history=HistoryPolicy.KEEP_LAST,
            depth=1,
        )

        # PX4에 offboard 관련 명령을 보내는 publisher 3개를 만든다.
        # 1) OffboardControlMode: 어떤 제어 방식(position, velocity 등)을 쓸지 알림
        # 2) TrajectorySetpoint: 실제 목표 위치/자세
        # 3) VehicleCommand: 모드 전환 같은 명령
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

        # PX4에서 현재 기체 위치와 상태를 받아오는 subscriber를 만든다.
        self.create_subscription(
            VehicleLocalPosition,
            '/fmu/out/vehicle_local_position',
            self.vehicle_local_position_callback,
            qos_profile,
        )
        self.create_subscription(
            VehicleStatus,
            '/fmu/out/vehicle_status',
            self.vehicle_status_callback,
            qos_profile,
        )

        # 기체가 "지금 이 자리"에 머물도록 하기 위한 기준 위치/방향이다.
        # 처음에는 위치를 아직 모르므로 0으로 시작하고, 실제 메시지를 받으면 갱신한다.
        self.reference_position = [0.0, 0.0, 0.0]
        self.reference_yaw = 0.0
        self.has_reference_position = False

        # offboard 모드 명령을 여러 번 보내지 않도록 상태를 저장한다.
        self.offboard_command_sent = False
        self.offboard_setpoint_counter = 0
        self.last_nav_state = None

        # timer_period 마다 timer_callback을 실행한다.
        # 이 콜백 안에서 offboard 메시지와 setpoint를 계속 보낸다.
        self.timer = self.create_timer(timer_period, self.timer_callback)
        self.get_logger().info('Offboard mode node started. The node does not arm or take off.')

    def vehicle_local_position_callback(self, msg: VehicleLocalPosition) -> None:
        # 위치 값이 유효하지 않으면 기준점으로 사용하면 안 된다.
        if not (msg.xy_valid and msg.z_valid):
            return

        # 현재 기체 위치를 "유지할 목표 위치"로 저장한다.
        self.reference_position = [msg.x, msg.y, msg.z]

        # heading 값이 정상 숫자일 때만 yaw 기준값으로 사용한다.
        if math.isfinite(msg.heading):
            self.reference_yaw = msg.heading

        # 처음으로 유효한 위치를 받았을 때만 로그를 남긴다.
        if not self.has_reference_position:
            self.has_reference_position = True
            self.get_logger().info(
                'Captured hold setpoint at '
                f'x={msg.x:.2f}, y={msg.y:.2f}, z={msg.z:.2f}, yaw={self.reference_yaw:.2f}'
            )

    def vehicle_status_callback(self, msg: VehicleStatus) -> None:
        # nav_state가 바뀌었을 때만 로그를 찍어 로그가 너무 많아지는 것을 막는다.
        if msg.nav_state != self.last_nav_state:
            self.last_nav_state = msg.nav_state
            self.get_logger().info(f'PX4 nav_state changed to {msg.nav_state}')

            # PX4가 실제로 offboard 모드에 들어갔는지 확인한다.
            if msg.nav_state == VehicleStatus.NAVIGATION_STATE_OFFBOARD:
                self.get_logger().info('PX4 is now in offboard mode.')

    def timer_callback(self) -> None:
        # PX4는 offboard 모드에 들어가기 전에도 관련 메시지가 먼저 들어와야 한다.
        # 그래서 타이머가 돌 때마다 제어 모드와 목표 위치를 계속 보낸다.
        self.publish_offboard_control_mode()
        self.publish_hold_setpoint()

        # 일정 횟수 이상 setpoint를 보낸 뒤에만 offboard 모드 전환 명령을 보낸다.
        if not self.offboard_command_sent and self.offboard_setpoint_counter >= self.warmup_setpoints:
            self.publish_vehicle_command(
                VehicleCommand.VEHICLE_CMD_DO_SET_MODE,
                # param1=1, param2=6 은 PX4에서 offboard 모드 전환에 쓰는 값이다.
                param1=1.0,
                param2=6.0,
            )
            self.offboard_command_sent = True
            self.get_logger().info('Offboard mode command sent. No arm command will be sent.')

        # 아직 offboard 명령을 보내기 전이라면 예열용 setpoint 개수를 센다.
        if not self.offboard_command_sent:
            self.offboard_setpoint_counter += 1

    def publish_offboard_control_mode(self) -> None:
        # position 제어를 사용하겠다는 메시지를 만든다.
        msg = OffboardControlMode()
        msg.position = True
        msg.velocity = False
        msg.acceleration = False
        msg.attitude = False
        msg.body_rate = False
        msg.timestamp = self.now_us()
        self.offboard_control_mode_publisher.publish(msg)

    def publish_hold_setpoint(self) -> None:
        # 현재 저장된 기준 위치와 yaw를 목표값으로 보낸다.
        # 즉, "새로운 목적지"가 아니라 "지금 위치 유지"에 가깝다.
        msg = TrajectorySetpoint()
        msg.position = self.reference_position
        msg.yaw = self.reference_yaw
        msg.timestamp = self.now_us()
        self.trajectory_setpoint_publisher.publish(msg)

        # 시작 직후 아직 위치를 못 받은 상태라면 경고를 한 번 남긴다.
        if not self.has_reference_position and self.offboard_setpoint_counter == 0:
            self.get_logger().warn(
                'VehicleLocalPosition has not been received yet. Publishing a zero hold setpoint until valid data arrives.'
            )

    def publish_vehicle_command(self, command: int, **params: float) -> None:
        # PX4 명령 메시지를 만들고, 필요한 파라미터(param1~param7)를 채운다.
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
    node = OffboardModeNode()

    try:
        # 콜백(timer, subscriber)을 계속 실행한다.
        rclpy.spin(node)
    finally:
        # 프로그램 종료 시 노드와 ROS 자원을 정리한다.
        node.destroy_node()
        rclpy.shutdown()


if __name__ == '__main__':
    main()
