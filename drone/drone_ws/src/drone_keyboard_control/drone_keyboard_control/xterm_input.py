# Drone xterm의 X11 키 이벤트를 활성 tmux pane에 한정하고 터미널 입력을 정리합니다.
from contextlib import contextmanager
import os
from pathlib import Path
import subprocess
import termios
import time

from Xlib import X, XK, display, error


# FLIGHT_KEYS는 X11 키맵의 기본 기호로 조회할 물리 조종 키입니다.
FLIGHT_KEYS = (
    "w", "s", "a", "d", "q", "e", "p", "Shift_L", "Shift_R", "Control_L", "Control_R",
)


@contextmanager
def quiet_terminal():
    """전경 pane의 입력 에코를 끄고 Ctrl+C를 유지하며 종료 시 설정을 복원합니다."""
    # tty는 ROS launch가 표준 입력을 리다이렉트해도 같은 pane에 연결되는 제어 터미널입니다.
    with open("/dev/tty", "rb", buffering=0) as tty:
        if os.tcgetpgrp(tty.fileno()) != os.getpgrp():
            raise RuntimeError("Run keyboard control in the foreground of the Drone shell.")
        # original은 복원할 설정이며 settings는 조종 중 쓸 독립적인 설정 사본입니다.
        original = termios.tcgetattr(tty)
        settings = termios.tcgetattr(tty)
        settings[0] &= ~termios.IXON  # Ctrl+S가 하강·후진 중 터미널 출력을 멈추지 않게 합니다.
        settings[3] &= ~(termios.ECHO | termios.ECHONL)
        settings[6][termios.VSUSP] = b"\0"  # Ctrl+Z로 조종 루프가 정지하지 않게 합니다.
        termios.tcsetattr(tty, termios.TCSAFLUSH, settings)
        try:
            yield tty
        finally:
            termios.tcsetattr(tty, termios.TCSAFLUSH, original)


def active_clients(pane):
    """조종 pane을 보고 있고 tmux 명령 모드에 있지 않은 쓰기 가능한 클라이언트를 찾습니다."""
    try:
        # rows는 tmux 서버가 각 클라이언트의 현재 상태를 한 줄씩 스냅샷한 결과입니다.
        rows = subprocess.check_output(
            ["tmux", "list-clients", "-F",
             "#{client_pid} #{pane_id} #{client_readonly} #{pane_in_mode} #{client_key_table}"],
            text=True, stderr=subprocess.DEVNULL, timeout=0.1,
        ).splitlines()
    except (OSError, subprocess.SubprocessError):
        return set()
    # pid는 tmux 클라이언트를 X11 창과 연결하고 state는 pane, 읽기 전용, 복사 모드와 키 테이블을 담습니다.
    return {int(pid) for pid, *state in map(str.split, rows)
            if state == [pane, "0", "0", "root"]}


class XtermInput:
    """명령을 실행한 xterm의 키를 추적하고 포커스가 끊기면 눌린 키를 지웁니다."""

    def __init__(self, connection, pane):
        """X11 연결에서 조종 pane을 열어 둔 xterm을 찾고 입력 이벤트를 구독합니다."""
        # connection은 xterm과 같은 X 서버를 참조하고 pane은 launch를 실행한 tmux pane ID입니다.
        self.connection = connection
        self.pane = pane
        # focus는 여러 클라이언트가 같은 pane을 열었을 때 명령을 실행한 xterm을 식별합니다.
        focus = getattr(connection.get_input_focus().focus, "id", None)
        # candidates는 활성 pane과 연결된 tmux 클라이언트별 xterm 및 하위 입력 창입니다.
        candidates = {}
        for pid in active_clients(pane):
            try:
                # environ은 해당 tmux 클라이언트가 시작될 때 호스트 xterm에서 전달받은 환경입니다.
                environ = Path(f"/proc/{pid}/environ").read_bytes().split(b"\0")
                # entry는 xterm이 설정한 X11 창 ID를 담은 환경 항목입니다.
                entry = next(item for item in environ if item.startswith(b"WINDOWID="))
                # window는 xterm의 최상위 X11 창이며 자식은 VT 위젯 등 이벤트 대상입니다.
                window = connection.create_resource_object("window", int(entry.split(b"=", 1)[1]))
                candidates[pid] = self.window_tree(window)
            except (OSError, StopIteration, ValueError, error.BadWindow):
                continue
        # focused는 후보 중 X11 키보드 포커스가 있는 클라이언트입니다.
        focused = [pid for pid, windows in candidates.items() if focus in windows]
        if not focused and len(candidates) == 1:
            focused = list(candidates)
        if len(focused) != 1:
            raise RuntimeError("Start the launch in the active pane of the Drone xterm.")
        # client_pid와 windows는 시작한 xterm에만 조종 입력을 한정합니다.
        self.client_pid = focused[0]
        self.windows = candidates[self.client_pid]
        # mask는 포커스 변경과 키 이벤트를 받되 xterm 자체의 입력 처리는 그대로 둡니다.
        mask = X.FocusChangeMask | X.KeyPressMask | X.KeyReleaseMask
        for window in self.windows.values():
            window.change_attributes(event_mask=mask)
        connection.sync()
        # names는 X11 기호, codes는 실제 이벤트 키코드를 정규화된 조종 키 이름에 연결합니다.
        names = {getattr(XK, f"XK_{key}"): key.lower() for key in FLIGHT_KEYS}
        self.codes = {
            code: names[connection.keycode_to_keysym(code, 0)]
            for code in range(8, 256) if connection.keycode_to_keysym(code, 0) in names
        }
        # pressed는 현재 눌린 키코드이며 blocked는 포커스를 얻기 전부터 눌려 있던 키코드입니다.
        self.pressed = set()
        self.blocked = set()
        # active는 창과 pane이 함께 활성 상태인지, next_check는 다음 tmux 검사 시각입니다.
        self.active = False
        self.next_check = 0.0
        # pane_active는 다음 tmux 검사까지 유지할 최신 활성 pane 스냅샷입니다.
        self.pane_active = False

    @staticmethod
    def window_tree(window):
        """window와 현재 자식을 키보드 이벤트를 받을 수 있는 창 ID로 색인합니다."""
        # windows는 현재 창과 재귀 조회한 모든 자식 창을 같은 매핑에 합칩니다.
        windows = {window.id: window}
        for child in window.query_tree().children:
            windows.update(XtermInput.window_tree(child))
        return windows

    def read(self):
        """현재 조종 키 집합과 이 주기에 P가 새로 눌렸는지 반환합니다."""
        # now는 50 ms 간격으로 tmux 상태를 확인하는 단조 시각입니다.
        now = time.monotonic()
        if now >= self.next_check:
            self.pane_active = self.client_pid in active_clients(self.pane)
            self.next_check = now + 0.05
        # focus 응답은 이전 X 이벤트도 큐에 넣어 짧은 포커스 상실을 감지할 수 있게 합니다.
        focus = getattr(self.connection.get_input_focus().focus, "id", None)
        # events는 이번 주기에 큐에 들어온 이벤트로 자동 반복의 해제·누름 쌍까지 포함합니다.
        events = [self.connection.next_event() for _ in range(self.connection.pending_events())]
        if (not self.pane_active or focus not in self.windows
                or any(event.type == X.FocusOut and event.detail != X.NotifyInferior
                       for event in events)):
            self.active = False
            self.pressed.clear()
            return set(), False

        if not self.active:
            # keymap은 이미 누르고 있던 키의 비트맵으로, 실제 해제 후에만 다시 활성화합니다.
            keymap = self.connection.query_keymap()
            self.blocked = {code for code in self.codes if keymap[code // 8] & (1 << (code % 8))}
            self.active = True
            return set(), False

        # arm은 P의 첫 누름 에지만 기록하며 한 주기 안에 P를 놓아도 시동을 요청합니다.
        arm = False
        for index, event in enumerate(events):
            if event.type not in (X.KeyPress, X.KeyRelease) or event.send_event:
                continue
            # code는 Shift 또는 Ctrl에 의해 문자 기호가 달라져도 바뀌지 않는 키코드입니다.
            code = event.detail
            if code not in self.codes:
                continue
            if event.type == X.KeyRelease:
                # following은 X11 자동 반복에서 해제와 같은 시각으로 생성된 누름 이벤트입니다.
                following = events[index + 1] if index + 1 < len(events) else None
                if (following is not None and following.type == X.KeyPress
                        and following.detail == code and following.time == event.time):
                    continue
                self.blocked.discard(code)
                self.pressed.discard(code)
            elif code not in self.blocked and code not in self.pressed:
                self.pressed.add(code)
                arm |= self.codes[code] == "p"
        return {self.codes[code] for code in self.pressed}, arm
