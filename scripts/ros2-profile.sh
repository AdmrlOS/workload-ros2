#!/bin/bash
# Sourced by interactive login shells (SSH sessions) so the `ros2` CLI works
# immediately. The workload's /start.sh performs its own sourcing.
if [ -f /run/ros2-demo/environment ]; then
    . /run/ros2-demo/environment
fi
for _ros_setup in /opt/ros/*/setup.bash; do
    if [ -f "$_ros_setup" ]; then
        # shellcheck disable=SC1090
        . "$_ros_setup"
        break
    fi
done
unset _ros_setup
