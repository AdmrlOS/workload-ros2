# Admiral ROS 2 workload

A headless [ROS 2](https://docs.ros.org/) demo for
[Admiral](https://admrl.co). A C++ talker publishes `std_msgs/String` messages on
`/chatter`; a Python listener receives them through CycloneDDS. Run both in one
workload, or deploy them to separate devices to demonstrate ROS 2 discovery
across a network.

Admiral uses the OCI image as the device's application userspace. This image
includes a supervisor that starts the nodes, restarts services that exit, and
forwards shutdown signals. Optional SSH provides key-only access to the ROS CLI.
No robot hardware is required.

- **Repository:** [AdmrlOS/workload-ros2](https://github.com/AdmrlOS/workload-ros2)
- **Release image:** `ghcr.io/admrlos/workload-ros2:<version>` (published by version tags)
- **Platforms:** `linux/amd64`, `linux/arm64`
- **Base:** ROS 2 Lyrical on Ubuntu Resolute, pinned by multi-architecture digest
- **License:** [MIT](LICENSE)

## Build and run

Install Docker with Buildx, then run from the repository root:

```sh
docker build -t workload-ros2:local .
docker run --rm --name ros2-demo workload-ros2:local
```

The logs should show the talker's `Publishing:` messages and the listener's
`I heard: [Hello World: ...]`. Stop with Ctrl+C.

The `ROS_IMAGE` build argument allows another ROS base, for example Jazzy:

```sh
docker build --build-arg ROS_IMAGE=ros:jazzy-ros-base-noble \
  -t workload-ros2:jazzy .
```

The default base is digest-pinned; apt packages are resolved at build time.
Deploy the resulting image by digest when exact image identity matters.
Alternative ROS releases need their own build and runtime validation.

## Deploy on Admiral

Build and publish an image first, or use a version published by the release
workflow. Create an Admiral configuration with these settings:

| Setting | Value |
| --- | --- |
| Workload image | `ghcr.io/admrlos/workload-ros2:<version>`, preferably pinned by digest |
| Command | Leave empty to use `/start.sh` |
| Interactive Mode | Off |
| Host Network | On for discovery between devices |
| Root filesystem | Writable |
| Persistent volume | Mount a Custom Volume at `/data` |
| Hardware access | None required for the demo |

ROS logs are stored at `/data/ros/log`. When SSH is enabled, its host key is
stored at `/data/ssh/host_ed25519`; persisting `/data` keeps the device's SSH
identity stable across workload updates.

For a two-device demo, put the devices on a network that passes UDP multicast:

| Variable | Device A | Device B |
| --- | --- | --- |
| `DEMO_MODE` | `talker` | `listener` |
| `ROS_DOMAIN_ID` | `42` | `42` |

Use the same DDS implementation on both devices. Device B's workload log should
show `I heard: [Hello World: ...]` from Device A. Host networking alone does not
override firewall rules, Wi-Fi client isolation, or multicast filtering.

Deploy a new version tag or digest for each update. Reusing an existing tag can
leave a device running its cached image. Keep durable state under `/data` and
use Admiral configuration versions for rollback.

## Configuration

Set these environment variables in the Admiral configuration or with Docker's
`-e`. The startup script supplies defaults even when image environment values
are not inherited by the launcher.

| Variable | Default | Purpose |
| --- | --- | --- |
| `DEMO_MODE` | `both` | `both`, `talker`, `listener`, or `custom`. |
| `ROS_DOMAIN_ID` | `0` | DDS domain; must match across participants. Valid range: `0`–`232`; `0`–`101` is a practical choice on Linux. |
| `RMW_IMPLEMENTATION` | `rmw_cyclonedds_cpp` | ROS middleware implementation. CycloneDDS is installed and used by default. |
| `LAUNCH_COMMAND` | Empty | Required for `DEMO_MODE=custom`; runs under Bash and is restarted if it exits. |
| `WAIT_FOR_NETWORK` | `true` | Wait for a global IPv4 address before starting DDS participants. |
| `NETWORK_WAIT_TIMEOUT` | `30` | Maximum wait in seconds, checked every two seconds; start anyway after the timeout. Set `WAIT_FOR_NETWORK=false` to skip the wait. |
| `ROS_LOG_DIR` | `/data/ros/log` | ROS log directory; falls back to `$HOME/.ros/log` if unavailable. |
| `ENABLE_SSH` | `false` | Set to `true` to start the diagnostic SSH server. |
| `SSH_AUTHORIZED_KEYS` | Empty | Public key(s), separated by newlines, added to root's authorized keys. Supply public keys only. |
| `SSH_PORT` | `22` | SSH listening port; choose a free port when using host networking. |
| `SSH_KEY_DIR` | `/data/ssh` | Persistent SSH host-key directory. |

Discovery options such as `CYCLONEDDS_URI` can also be supplied. SSH login shells
and the `ros2` wrapper inherit the workload's ROS domain, middleware, logging,
and discovery settings. Other workload environment values are not copied to
SSH sessions.

### Your own nodes

Add packages to the Dockerfile, or extend this image with a built ROS workspace.
Use a custom command to select your application:

```sh
docker run --rm -e DEMO_MODE=custom \
  -e LAUNCH_COMMAND='ros2 launch my_package my_launch.py' \
  my-ros-workload:local
```

The custom command must remain in the foreground. The demo supervisor restarts
it after any exit, including exit code zero.

## Local checks

Run the integration smoke test after building:

```sh
python3 tests/smoke.py workload-ros2:local
```

It requires Python 3, Docker, and OpenSSH client tools. It checks message
exchange within and between containers, health checks, service restart,
startup without inherited image environment values, custom-command shutdown,
invalid configuration, and key-only SSH with the matching ROS environment.
Temporary containers, networks, and test keys are cleaned up automatically.
These checks do not establish discovery on a particular Admiral device or LAN.

To try the two-workload demo manually:

```sh
docker network create ros2-demo
docker run -d --name ros2-talker --network ros2-demo \
  -e ROS_DOMAIN_ID=42 -e DEMO_MODE=talker workload-ros2:local
docker run -d --name ros2-listener --network ros2-demo \
  -e ROS_DOMAIN_ID=42 -e DEMO_MODE=listener workload-ros2:local
docker logs -f ros2-listener
```

Stop following the logs with Ctrl+C, then clean up:

```sh
docker rm -f ros2-talker ros2-listener
docker network rm ros2-demo
```

### SSH diagnostics

Supply your public key at runtime. For a local check:

```sh
docker run -d --name ros2-ssh -p 127.0.0.1:2222:22 \
  -e ENABLE_SSH=true -e ROS_DOMAIN_ID=42 \
  -e SSH_AUTHORIZED_KEYS="$(cat "$HOME/.ssh/id_ed25519.pub")" \
  -v ros2-demo-data:/data workload-ros2:local
ssh -i "$HOME/.ssh/id_ed25519" -p 2222 root@localhost 'ros2 topic list'
ssh -i "$HOME/.ssh/id_ed25519" -p 2222 root@localhost 'ros2 topic echo /chatter'
docker rm -f ros2-ssh
```

Password and keyboard-interactive authentication are disabled. On Admiral with
host networking, connect to the device's IP and `SSH_PORT` directly. Check the
host-key fingerprint when connecting for the first time or replacing a device.

## Troubleshooting

If the listener receives nothing:

1. Confirm the devices share the same `ROS_DOMAIN_ID` and use the intended RMW.
2. Check reachability with `ping <peer-ip>` and ensure discovery has not been
   restricted to localhost by the configuration.
3. Test multicast separately: run `ros2 multicast receive` on one device and
   `ros2 multicast send` on the other. Check Wi-Fi client isolation, firewall
   rules, VLANs, and multicast filtering if messages do not arrive.
4. On a device with multiple interfaces, select one through `CYCLONEDDS_URI`,
   for example:

   ```xml
   <CycloneDDS><Domain><General><Interfaces><NetworkInterface name="wlan0"/></Interfaces></General></Domain></CycloneDDS>
   ```

Useful commands inside the workload or over SSH:

```sh
ros2 node list
ros2 topic list
ros2 topic echo /chatter
cat /run/ros2-demo/*.pid
/healthcheck.sh
```

The supervisor and nodes write to workload stdout/stderr. The health check
verifies that expected processes are alive; it does not verify DDS traffic.
Docker uses the image's `HEALTHCHECK`; verify health through Admiral's workload
logs and observed messages on the target device.

## Release images

GitHub Actions builds and smoke-tests AMD64 and ARM64 on pushes to `main`, pull
requests, and manual runs. Pushing a version tag also runs those checks, then
publishes a multi-architecture image to GHCR using `GITHUB_TOKEN`.
For example, to publish version `0.3.0` from a committed revision:

```sh
git tag v0.3.0
git push origin v0.3.0
```

The workflow publishes `ghcr.io/admrlos/workload-ros2:0.3.0` and a
`sha-<full-commit>` tag. It does not publish `latest`. Use a fresh version for
each release, and record the published digest for deployment. Repository
publication and GHCR package visibility are separate: make the package public
in its GitHub package settings if devices should pull without credentials.

For a manual multi-architecture build, log in to your registry and choose an
unused version:

```sh
VERSION=0.3.0  # Choose an unused version.
docker buildx build --platform linux/amd64,linux/arm64 \
  -t "ghcr.io/admrlos/workload-ros2:${VERSION}" --push .
```

## Repository layout

```text
Dockerfile                  ROS image, packages, and workload metadata
scripts/start.sh            Workload supervisor
scripts/healthcheck.sh      Process health check
scripts/ros2-cli.sh          CLI wrapper for non-login shells
scripts/ros2-profile.sh      ROS environment for login shells
tests/smoke.py               Docker integration checks
.github/workflows/ci.yml     Validation and version-tag publishing
LICENSE                     MIT license for this repository
```

ROS, Ubuntu, and other components in the image retain their upstream licenses.
See the [official ROS image sources](https://github.com/osrf/docker_images) for
base-image details and the [Admiral documentation](https://docs.admrl.co/) for
platform configuration.
