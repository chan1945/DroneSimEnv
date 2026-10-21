#!/usr/bin/env bash
set -Eeuo pipefail

# QGC_PID stores the QGroundControl process ID for cleanup.
QGC_PID=''
# KEEPALIVE_PID stores the process ID that keeps the container running.
KEEPALIVE_PID=''

# cleanup stops the child processes when the container exits.
cleanup() {
    if [[ -n "$QGC_PID" ]]; then
        kill "$QGC_PID" 2>/dev/null || true
        wait "$QGC_PID" 2>/dev/null || true
    fi
    if [[ -n "$KEEPALIVE_PID" ]]; then
        kill "$KEEPALIVE_PID" 2>/dev/null || true
        wait "$KEEPALIVE_PID" 2>/dev/null || true
    fi
}

trap cleanup EXIT
trap 'exit 0' INT TERM

if [[ -n "${DISPLAY:-}" || -n "${WAYLAND_DISPLAY:-}" ]]; then
    echo 'Starting QGroundControl...'
    gosu qgcuser env \
        HOME=/home/qgcuser \
        DISPLAY="${DISPLAY:-}" \
        WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-}" \
        XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-}" \
        PULSE_SERVER="${PULSE_SERVER:-}" \
        QT_X11_NO_MITSHM="${QT_X11_NO_MITSHM:-1}" \
        qgc >/tmp/qgc.log 2>&1 &
    QGC_PID=$!
    echo 'QGroundControl started. Logs: /tmp/qgc.log'
else
    echo 'Skipping QGroundControl startup because no GUI display variables are set.'
fi

tail -f /dev/null &
KEEPALIVE_PID=$!
wait "$KEEPALIVE_PID"
