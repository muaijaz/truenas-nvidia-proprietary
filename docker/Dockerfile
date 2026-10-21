FROM debian:12
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc-12 make kmod squashfs-tools libelf-dev bc file xz-utils ca-certificates \
    && ln -sf /usr/bin/gcc-12 /usr/bin/gcc && ln -sf /usr/bin/gcc-12 /usr/bin/cc \
    && rm -rf /var/lib/apt/lists/*
