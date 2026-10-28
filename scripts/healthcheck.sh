#!/bin/bash
set -u

RUNTIME_DIR="/run/ros2-demo"
DEMO_MODE="${DEMO_MODE:-both}"
ENABLE_SSH="${ENABLE_SSH:-false}"

alive() {
    local pidfile="$1" pid
    [ -f "$pidfile" ] || return 1
    pid="$(cat "$pidfile" 2>/dev/null)"
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
    kill -0 "$pid" 2>/dev/null
}

status=0
case "$DEMO_MODE" in
    both)
        alive "$RUNTIME_DIR/talker.pid" || status=1
        alive "$RUNTIME_DIR/listener.pid" || status=1
        ;;
    talker)
        alive "$RUNTIME_DIR/talker.pid" || status=1
        ;;
    listener)
        alive "$RUNTIME_DIR/listener.pid" || status=1
        ;;
    custom)
        alive "$RUNTIME_DIR/custom.pid" || status=1
        ;;
    *)
        status=1
        ;;
esac

if [ "$ENABLE_SSH" = "true" ]; then
    alive "$RUNTIME_DIR/sshd.pid" || status=1
fi

exit "$status"
