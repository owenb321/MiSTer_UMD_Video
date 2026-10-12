# Pinned build image for the HIL Main (main/README.md) -- the ARM cross toolchain
# (gcc-arm 10.2-2020.11, arm-none-linux-gnueabihf), baked in so the Docker build is
# self-contained and reproducible. HARVESTED from MiSTer_DVD main/docker/Dockerfile
# unchanged in substance (its notes: the bookworm base supplies only wget / make / git /
# python3 -- the compiler is the pinned tarball below, the codegen pin -- and the base
# was measured to contribute zero difference to the binary).
#
# Build:  docker build -t mister-umd-main:gcc-arm-10.2 main/docker
# (build_main.sh builds it automatically on first USE_DOCKER=1 run.)
FROM debian:bookworm-slim

# Toolchain pin — must match the version CLAUDE.md / the local build uses. Bumping
# it changes codegen (and can change the VFP baseline), so treat like a seed re-roll.
ARG TC=gcc-arm-10.2-2020.11-x86_64-arm-none-linux-gnueabihf
ARG TC_URL=https://developer.arm.com/-/media/Files/downloads/gnu-a/10.2-2020.11/binrel/${TC}.tar.xz

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates wget xz-utils git make python3 \
    && rm -rf /var/lib/apt/lists/*

RUN wget -q "${TC_URL}" -O /tmp/tc.tar.xz \
    && mkdir -p /opt/toolchain \
    && tar -xJf /tmp/tc.tar.xz -C /opt/toolchain --strip-components=1 \
    && rm /tmp/tc.tar.xz

ENV PATH="/opt/toolchain/bin:${PATH}"
