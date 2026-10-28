# Multi-architecture ROS 2 Lyrical base, pinned on 2026-10-29.
ARG ROS_IMAGE=ros:lyrical-ros-base-resolute@sha256:3224ee150cb02eb89a5e0811bc267b57ed3a91b9c10191df57810726a7e916d7
FROM ${ROS_IMAGE}

LABEL org.opencontainers.image.title="Admiral ROS 2 workload" \
      org.opencontainers.image.description="Supervised C++ talker and Python listener with CycloneDDS and optional key-only SSH." \
      org.opencontainers.image.source="https://github.com/AdmrlOS/workload-ros2" \
      org.opencontainers.image.licenses="MIT"

# /start.sh also supplies these defaults when image ENV is not inherited.
ENV ROS_DOMAIN_ID=0 \
    DEMO_MODE=both \
    LAUNCH_COMMAND="" \
    RMW_IMPLEMENTATION=rmw_cyclonedds_cpp \
    ENABLE_SSH=false \
    SSH_PORT=22 \
    ROS_LOG_DIR=/data/ros/log \
    WAIT_FOR_NETWORK=true \
    NETWORK_WAIT_TIMEOUT=30 \
    PYTHONUNBUFFERED=1

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        procps iproute2 iputils-ping openssh-server util-linux \
        "ros-${ROS_DISTRO}-demo-nodes-cpp" \
        "ros-${ROS_DISTRO}-demo-nodes-py" \
        "ros-${ROS_DISTRO}-rmw-cyclonedds-cpp" && \
    rm -rf /var/lib/apt/lists/* /etc/ssh/ssh_host_*

COPY scripts/start.sh /start.sh
COPY scripts/healthcheck.sh /healthcheck.sh
COPY scripts/ros2-cli.sh /usr/local/bin/ros2
COPY scripts/ros2-profile.sh /etc/profile.d/ros2.sh
COPY LICENSE /usr/share/doc/workload-ros2/LICENSE
RUN chmod 755 /start.sh /healthcheck.sh /usr/local/bin/ros2

USER root
WORKDIR /root
# Admiral launches the complete userspace; source ROS in /start.sh itself.
ENTRYPOINT []
HEALTHCHECK --interval=30s --timeout=5s --start-period=45s --retries=3 \
    CMD ["/healthcheck.sh"]
CMD ["/start.sh"]
