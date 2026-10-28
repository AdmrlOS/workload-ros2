#!/usr/bin/env python3
"""Exercise a built image through Docker; no ROS installation needed on the host."""
import contextlib
import pathlib
import subprocess
import sys
import tempfile
import time
import uuid

IMAGE = sys.argv[1] if len(sys.argv) > 1 else "workload-ros2:local"
PREFIX = "ros2-smoke-" + uuid.uuid4().hex[:10]


def run(*args, check=True, timeout=30):
    return subprocess.run(args, text=True, stdout=subprocess.PIPE,
                          stderr=subprocess.STDOUT, check=check, timeout=timeout)


def docker(*args, **kwargs):
    return run("docker", *args, **kwargs)


def until(description, predicate, seconds=45):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(1)
    raise AssertionError("Timed out: " + description)


@contextlib.contextmanager
def container(suffix, *options, command=()):
    name = PREFIX + "-" + suffix
    docker("run", "-d", "--name", name, *options, IMAGE, *command)
    try:
        yield name
    except BaseException:
        print(docker("logs", name, check=False).stdout, file=sys.stderr)
        raise
    finally:
        docker("rm", "-f", name, check=False)


def logs_contain(name, text):
    return text in docker("logs", name).stdout


def healthy(name):
    until(name + " healthy", lambda: docker("exec", name, "/healthcheck.sh",
                                            check=False).returncode == 0)


def stop(name):
    docker("stop", "-t", "15", name)
    assert docker("inspect", "-f", "{{.State.ExitCode}}", name).stdout.strip() == "0"


def main():
    # The published image must not contain shared SSH private host keys.
    docker("run", "--rm", "--entrypoint", "/bin/bash", IMAGE, "-ec",
           'test -z "$(find /etc/ssh -name \'ssh_host_*\' -print -quit)"')
    with container("both", "-e", "ROS_DOMAIN_ID=42") as name:
        until("C++ to Python delivery", lambda: logs_contain(name, "I heard:"))
        healthy(name)
        old_pid = docker("exec", name, "cat", "/run/ros2-demo/talker.pid").stdout.strip()
        docker("exec", name, "bash", "-c", 'kill -TERM -- "-$(cat /run/ros2-demo/talker.pid)"')
        until("talker restarted", lambda: docker("exec", name, "cat",
              "/run/ros2-demo/talker.pid").stdout.strip() != old_pid)
        healthy(name)
        stop(name)
    print("PASS: talker/listener, health, restart, clean stop", flush=True)

    network = PREFIX + "-network"
    docker("network", "create", network)
    try:
        with container("talker", "--network", network, "-e", "DEMO_MODE=talker",
                       "-e", "ROS_DOMAIN_ID=42") as talker:
            with container("listener", "--network", network, "-e", "DEMO_MODE=listener",
                           "-e", "ROS_DOMAIN_ID=42") as listener:
                until("DDS between containers", lambda: logs_contain(listener, "I heard:"))
                healthy(talker)
                healthy(listener)
    finally:
        docker("network", "rm", network, check=False)
    print("PASS: discovery and traffic between separate workloads", flush=True)

    with container("empty-env", command=("env", "-i", "WAIT_FOR_NETWORK=false", "/start.sh")) as name:
        until("default RMW without image ENV", lambda: logs_contain(name, "I heard:"))
        assert logs_contain(name, "RMW_IMPLEMENTATION=rmw_cyclonedds_cpp")
        healthy(name)
        stop(name)
    print("PASS: startup without inherited image environment", flush=True)

    command = "trap 'echo stopped > /data/custom-stopped' TERM; sleep 600 & wait"
    with container("custom", "-e", "DEMO_MODE=custom", "-e", "LAUNCH_COMMAND=" + command) as name:
        healthy(name)
        stop(name)
        with tempfile.TemporaryDirectory() as tmp:
            docker("cp", name + ":/data/custom-stopped", tmp + "/stopped")
            assert pathlib.Path(tmp, "stopped").read_text().strip() == "stopped"
    print("PASS: custom command receives shutdown signal", flush=True)

    for suffix, options, expected in (
        ("missing-command", ("-e", "DEMO_MODE=custom"), "requires LAUNCH_COMMAND"),
        ("bad-mode", ("-e", "DEMO_MODE=typo"), "DEMO_MODE must be"),
        ("bad-domain", ("-e", "ROS_DOMAIN_ID=999"), "ROS_DOMAIN_ID must be"),
        ("bad-timeout", ("-e", "NETWORK_WAIT_TIMEOUT=invalid"), "NETWORK_WAIT_TIMEOUT must be"),
    ):
        result = docker("run", "--rm", *options, IMAGE, check=False)
        assert result.returncode != 0 and expected in result.stdout, (suffix, result.stdout)
    print("PASS: invalid configuration fails visibly", flush=True)

    with tempfile.TemporaryDirectory() as tmp:
        key = str(pathlib.Path(tmp, "id_ed25519"))
        run("ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", key)
        public_key = pathlib.Path(key + ".pub").read_text().strip()
        with container("ssh", "-p", "127.0.0.1::22", "-e", "ENABLE_SSH=true",
                       "-e", "ROS_DOMAIN_ID=42", "-e", "NOT_ROS_SECRET=sentinel",
                       "-e", "SSH_AUTHORIZED_KEYS=" + public_key) as name:
            healthy(name)
            port = docker("port", name, "22/tcp").stdout.strip().rsplit(":", 1)[1]
            ssh = ("ssh", "-i", key, "-p", port, "-o", "BatchMode=yes",
                   "-o", "ConnectTimeout=3", "-o", "StrictHostKeyChecking=accept-new",
                   "-o", "UserKnownHostsFile=" + tmp + "/known_hosts", "root@127.0.0.1")
            until("key-only SSH", lambda: run(*ssh, "true", check=False).returncode == 0)
            result = run(*ssh, "ros2 topic list --no-daemon")
            assert "/chatter" in result.stdout, result.stdout
            result = run(*ssh, "bash -lc 'printf \"%s %s\" \"$ROS_DOMAIN_ID\" \"$RMW_IMPLEMENTATION\"'")
            assert "42 rmw_cyclonedds_cpp" in result.stdout, result.stdout
            exported = docker("exec", name, "cat", "/run/ros2-demo/environment").stdout
            assert "NOT_ROS_SECRET" not in exported and "sentinel" not in exported
            denied = run(*ssh[:-1], "-o", "PubkeyAuthentication=no", "-o",
                         "PreferredAuthentications=password", ssh[-1], "true", check=False)
            assert denied.returncode != 0 and "(publickey)" in denied.stdout, denied.stdout
            stop(name)
    print("PASS: key-only SSH, CLI discovery, matching ROS environment", flush=True)


if __name__ == "__main__":
    main()
