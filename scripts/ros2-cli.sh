#!/bin/bash
if [ -f /run/ros2-demo/environment ]; then
    . /run/ros2-demo/environment
fi
for _ros_setup in /opt/ros/*/setup.bash; do
    if [ -f "$_ros_setup" ]; then
        # shellcheck disable=SC1090
        . "$_ros_setup"
        # Sourcing prepends /opt/ros/<distro>/bin to PATH, so this resolves
        # to the real ros2 CLI rather than recursing into this wrapper.
        exec ros2 "$@"
    fi
done
echo "ros2 wrapper: no ROS 2 installation found under /opt/ros" >&2
exit 1
