# syntax=docker/dockerfile:1
#
# Images for the end-to-end test environment (see docker-compose.yml and ./test).
#
#   builder : compiles every example device + the device_validation helper
#   device  : runtime image for a single example device (one container each)
#   tests   : official chip-tool image + crystal toolchain + this repository, runs the specs
#
ARG CRYSTAL_VERSION=1.21.0
ARG CRYSTAL_IMAGE=crystallang/crystal:${CRYSTAL_VERSION}
# Official chip-tool (linux/amd64 + linux/arm64), built by the matter.js project from
# connectedhomeip. Tags are connectedhomeip commit SHAs; `latest` also exists.
ARG CHIP_TOOL_IMAGE=ghcr.io/matter-js/chip:3f1595e690f79ee3d18f174e720f53e73b80a859

# ---------------------------------------------------------------------------
FROM ${CRYSTAL_IMAGE} AS builder
WORKDIR /app
ENV CRYSTAL_CACHE_DIR=/root/.cache/crystal

COPY shard.yml shard.lock* ./
RUN shards install --skip-postinstall --skip-executables

COPY src ./src
COPY examples ./examples
COPY e2e/fixture ./e2e/fixture

# Build all `examples/matter_*_device.cr` into `bin/matter_*` (e.g. bin/matter_switch)
# plus the chip-tool driven validation helper used by the switch spec.
#
# Each build gets its own CRYSTAL_CACHE_DIR. Crystal keeps only the ten most
# recently used program directories in a cache root and deletes the rest at the
# start of every compile; with eleven programs sharing one root, a build would
# delete a sibling's directory while that sibling was still writing object files
# into it (`Error renaming file: ... No such file or directory`). Nothing is
# shared between the roots -- the cache is per program either way.
RUN --mount=type=cache,target=/root/.cache/crystal,sharing=locked \
    mkdir -p bin && \
    jobs="$(nproc)"; [ "$jobs" -gt 2 ] && jobs=2; \
    ls examples/matter_*_device.cr examples/device_validation.cr | \
      xargs -P "$jobs" -I{} sh -c 'name="$(basename {} .cr | sed "s/_device$//")"; echo "==> building bin/$name"; CRYSTAL_CACHE_DIR="/root/.cache/crystal/$name" crystal build {} -o "bin/$name" --error-trace' && \
    CRYSTAL_CACHE_DIR=/root/.cache/crystal/matter_door_lock_aliro crystal build e2e/fixture/matter_door_lock_aliro_device.cr -o bin/matter_door_lock_aliro --error-trace && \
    ls -la bin

# ---------------------------------------------------------------------------
FROM ${CRYSTAL_IMAGE} AS device
WORKDIR /app
COPY --from=builder /app/bin /app/bin
COPY e2e/device-entrypoint.sh /usr/local/bin/device-entrypoint
ENTRYPOINT ["device-entrypoint"]

# ---------------------------------------------------------------------------
FROM ${CHIP_TOOL_IMAGE} AS tests
ARG CRYSTAL_VERSION
WORKDIR /app
ENV CRYSTAL_CACHE_DIR=/root/.cache/crystal
ENV CHIP_TOOL=/usr/bin/chip-tool

# Crystal (same version as the builder) from the official release tarball, which
# is published for x86_64 and aarch64 (the apt repository is amd64 only), plus
# the packages crystal needs to link binaries. The image already ships chip-tool,
# avahi and dbus (both daemons must be running for chip-tool, see run.sh).
RUN apt-get update && apt-get install -y --no-install-recommends \
      curl ca-certificates git gcc make pkg-config \
      libpcre2-dev libevent-dev libgc-dev libssl-dev libyaml-dev libxml2-dev libgmp-dev zlib1g-dev \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /opt \
    && curl -fsSL "https://github.com/crystal-lang/crystal/releases/download/${CRYSTAL_VERSION}/crystal-${CRYSTAL_VERSION}-1-linux-$(uname -m).tar.gz" \
       | tar -xz -C /opt \
    && ln -s "/opt/crystal-${CRYSTAL_VERSION}-1/bin/crystal" /usr/local/bin/crystal \
    && ln -s "/opt/crystal-${CRYSTAL_VERSION}-1/bin/shards" /usr/local/bin/shards \
    && crystal --version \
    && chip-tool pairing code --help 2>&1 | grep -q -- --storage-directory

COPY --from=builder /app/lib /app/lib
COPY --from=builder /app/bin/device_validation /app/bin/device_validation
COPY shard.yml shard.lock* ./
COPY src ./src
COPY spec ./spec
COPY examples ./examples
COPY e2e ./e2e
ENTRYPOINT ["/app/e2e/run.sh"]
