#!/bin/bash
# ROS 2 appliance supervisor for Admiral-managed devices.
#
# Admiral unpacks the OCI image as the device's userspace and runs this script
# as the workload process. Docker-style ENV/PATH/WORKDIR inheritance is not
# guaranteed by the launcher, so this script:
#   * restores a baseline PATH/HOME itself,
#   * re-sources ROS 2 to rebuild PATH, AMENT_PREFIX_PATH, PYTHONPATH, etc.,
#   * uses absolute paths for system binaries it starts.
# It avoids Bash process substitution (Admiral runs workloads under crun in a
# PID namespace where /dev/fd may be absent) and supervises its services,
# restarting any that crash and shutting down cleanly on SIGTERM/SIGINT.

set -eu

STOP=0
trap 'STOP=1' TERM INT

# --------------------------------------------------------------- environment
export HOME="${HOME:-/root}"
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:${PATH}}"
export LANG="${LANG:-C.UTF-8}"
export PYTHONUNBUFFERED=1

# Reset values inherited from an unknown launcher so ROS 2's setup scripts
# rebuild them from scratch.
export PYTHONPATH=""
export LD_LIBRARY_PATH=""
export AMENT_PREFIX_PATH=""
export CMAKE_PREFIX_PATH=""

ROS_DOMAIN_ID="${ROS_DOMAIN_ID:-0}"
if ! [[ "$ROS_DOMAIN_ID" =~ ^(0|[1-9][0-9]{0,2})$ ]] || [ "$ROS_DOMAIN_ID" -gt 232 ]; then
    echo "[start] ERROR: ROS_DOMAIN_ID must be an integer from 0 to 232" >&2
    exit 1
fi
export ROS_DOMAIN_ID
export RMW_IMPLEMENTATION="${RMW_IMPLEMENTATION:-rmw_cyclonedds_cpp}"
echo "[start] RMW_IMPLEMENTATION=${RMW_IMPLEMENTATION}"

export ROS_LOG_DIR="${ROS_LOG_DIR:-/data/ros/log}"
mkdir -p "$ROS_LOG_DIR" 2>/dev/null || ROS_LOG_DIR="${HOME}/.ros/log"
mkdir -p "$ROS_LOG_DIR"

cd "${HOME}"

# ----------------------------------------------------------------- source ROS
ROS_SETUP=""
for candidate in /opt/ros/*/setup.bash; do
    if [ -f "$candidate" ]; then
        ROS_SETUP="$candidate"
        break
    fi
done
if [ -z "$ROS_SETUP" ]; then
    echo "[start] ERROR: no ROS 2 installation found under /opt/ros" >&2
    exit 1
fi
# ROS 2's generated setup scripts are not `set -u` clean (they reference
# AMENT_TRACE_SETUP_FILES etc. unquoted), so source them with -u disabled.
set +u
# shellcheck disable=SC1090
. "$ROS_SETUP"
set -u
ROS_ROOT_DIR="$(dirname "$ROS_SETUP")"
echo "[start] ROS 2 '$(basename "$ROS_ROOT_DIR")' sourced from ${ROS_ROOT_DIR}"
echo "[start] ROS_DOMAIN_ID=${ROS_DOMAIN_ID}"
echo "[start] ros2 CLI at: $(command -v ros2 || echo 'NOT FOUND')"

# -------------------------------------------------------------------- network
# The workload IS the device userspace: Wi-Fi/DHCP may still be settling when
# this script starts. A DDS participant created before any non-loopback
# interface has an address can end up permanently undiscoverable, so wait
# (bounded) for a usable interface before starting the services.
if [ "${WAIT_FOR_NETWORK:-true}" = "true" ]; then
    NETWORK_WAIT_TIMEOUT="${NETWORK_WAIT_TIMEOUT:-30}"
    if ! [[ "$NETWORK_WAIT_TIMEOUT" =~ ^(0|[1-9][0-9]{0,4})$ ]]; then
        echo "[start] ERROR: NETWORK_WAIT_TIMEOUT must be an integer from 0 to 99999" >&2
        exit 1
    fi
    waited=0
    until ip -o -4 addr show scope global 2>/dev/null | awk '{print $2}' | grep -qs -v '^lo$'; do
        if [ "$waited" -ge "$NETWORK_WAIT_TIMEOUT" ]; then
            echo "[start] WARNING: no non-loopback IPv4 after ${NETWORK_WAIT_TIMEOUT}s; starting anyway"
            break
        fi
        if [ "$waited" -eq 0 ]; then
            echo "[start] waiting for network (Wi-Fi/DHCP)..."
        fi
        sleep 2
        waited=$((waited + 2))
        [ "$STOP" -eq 0 ] || exit 0
    done
    echo "[start] network ready: $(ip -o -4 addr show scope global 2>/dev/null | awk '{printf "%s=%s ", $2, $4}')"
fi

# ------------------------------------------------------------------- services
declare -A CHILDREN
declare -A PIDS

DEMO_MODE="${DEMO_MODE:-both}"
case "$DEMO_MODE" in
    both|talker|listener|custom) ;;
    *)
        echo "[start] ERROR: DEMO_MODE must be both, talker, listener, or custom" >&2
        exit 1 ;;
esac

# sshd sanitizes its environment. Export only ROS settings for CLI sessions;
# never copy the complete workload environment, which can contain credentials.
RUNTIME_DIR="/run/ros2-demo"
mkdir -p "$RUNTIME_DIR"
chmod 700 "$RUNTIME_DIR"
rm -f "$RUNTIME_DIR"/*.pid
umask 077
{
    for name in ROS_DOMAIN_ID RMW_IMPLEMENTATION ROS_LOG_DIR CYCLONEDDS_URI \
                ROS_AUTOMATIC_DISCOVERY_RANGE ROS_STATIC_PEERS ROS_LOCALHOST_ONLY; do
        if [ -n "${!name:-}" ]; then
            printf 'export %s=%q\n' "$name" "${!name}"
        fi
    done
} > "$RUNTIME_DIR/environment"
umask 022

# The classic ROS 2 demo, split across client libraries to show C++/Python
# interoperability over DDS: a C++ talker publishing /chatter, a Python
# listener consuming it.
if [ "$DEMO_MODE" = "both" ] || [ "$DEMO_MODE" = "talker" ]; then
    CHILDREN[talker]="ros2 run demo_nodes_cpp talker"
fi
if [ "$DEMO_MODE" = "both" ] || [ "$DEMO_MODE" = "listener" ]; then
    CHILDREN[listener]="ros2 run demo_nodes_py listener"
fi
if [ "$DEMO_MODE" = "custom" ]; then
    if [ -z "${LAUNCH_COMMAND:-}" ]; then
        echo "[start] ERROR: DEMO_MODE=custom requires LAUNCH_COMMAND to be set" >&2
        exit 1
    fi
    CHILDREN[custom]="$LAUNCH_COMMAND"
fi

# Optional diagnostics SSH daemon: key-only root login, disabled by default.
# The host key is kept under SSH_KEY_DIR so a Custom Volume mounted at /data
# keeps it stable across workload filesystem replacements.
if [ "${ENABLE_SSH:-false}" = "true" ]; then
    SSH_PORT="${SSH_PORT:-22}"
    SSH_KEY_DIR="${SSH_KEY_DIR:-/data/ssh}"
    if ! [[ "$SSH_PORT" =~ ^[1-9][0-9]{0,4}$ ]] || [ "$SSH_PORT" -gt 65535 ]; then
        echo "[start] ERROR: SSH_PORT must be an integer from 1 to 65535" >&2
        exit 1
    fi
    mkdir -p "$SSH_KEY_DIR" /run/sshd
    SSH_HOST_KEY="$SSH_KEY_DIR/host_ed25519"
    if [ ! -f "$SSH_HOST_KEY" ]; then
        ssh-keygen -q -t ed25519 -N "" -f "$SSH_HOST_KEY"
        echo "[start] generated new SSH host key: $SSH_HOST_KEY"
    fi
    if [ -n "${SSH_AUTHORIZED_KEYS:-}" ]; then
        mkdir -p "$HOME/.ssh"
        printf '%s\n' "$SSH_AUTHORIZED_KEYS" >> "$HOME/.ssh/authorized_keys"
        sort -u -o "$HOME/.ssh/authorized_keys" "$HOME/.ssh/authorized_keys"
        chmod 700 "$HOME/.ssh"
        chmod 600 "$HOME/.ssh/authorized_keys"
    fi
    printf -v CHILDREN[sshd] '%q ' /usr/sbin/sshd -D -e -p "$SSH_PORT" \
        -o "HostKey=${SSH_HOST_KEY}" -o PermitRootLogin=prohibit-password \
        -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no \
        -o AuthenticationMethods=publickey
fi

# ----------------------------------------------------------------- supervisor
start_service() {
    local name="$1"
    local cmd="${CHILDREN[$name]}"
    echo "[start] starting '${name}': ${cmd}"
    setsid bash -c "$cmd" &
    PIDS[$name]=$!
    echo "${PIDS[$name]}" > "$RUNTIME_DIR/${name}.pid"
}

for name in "${!CHILDREN[@]}"; do
    [ "$STOP" -eq 0 ] || break
    start_service "$name"
done

# Restart crashed services; forward SIGTERM/SIGINT to a clean exit.
while [ "$STOP" -eq 0 ]; do
    for name in "${!CHILDREN[@]}"; do
        pid="${PIDS[$name]}"
        if ! kill -0 "$pid" 2>/dev/null; then
            wait "$pid" 2>/dev/null || true
            # Clean up any descendants before replacing the service group.
            kill -- "-$pid" 2>/dev/null || true
            echo "[start] service '${name}' (pid ${pid}) exited; restarting in 5s"
            sleep 5
            if [ "$STOP" -eq 0 ]; then
                start_service "$name"
            fi
        fi
    done
    sleep 2
done

echo "[start] shutting down"
for pid in "${PIDS[@]}"; do
    kill -- "-$pid" 2>/dev/null || true
done
sleep 2
for pid in "${PIDS[@]}"; do
    kill -9 -- "-$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
done
rm -f "$RUNTIME_DIR"/*.pid
exit 0
