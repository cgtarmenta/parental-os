# parental-os Ubuntu builder container.
#
# This ephemeral container runs debian/ubuntu package building and live ISO
# reconstruction tools (debootstrap, squashfs-tools, xorriso, etc.) in an
# isolated Ubuntu LTS (noble 24.04) environment without touching the host system.
FROM ubuntu:noble

ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=C.UTF-8

# Install build, packaging, debootstrap, live ISO generation, and scripting tools.
RUN apt-get update -qq \
    && apt-get install -y --no-install-recommends \
      build-essential \
      debhelper \
      dpkg-dev \
      fakeroot \
      debootstrap \
      squashfs-tools \
      xorriso \
      mtools \
      dosfstools \
      e2fsprogs \
      grub-pc-bin \
      grub-efi-amd64-bin \
      grub-common \
      zstd \
      rsync \
      git \
      jq \
      python3 \
      python3-yaml \
      ca-certificates \
      curl \
      wget \
      sudo \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /build

COPY build-edition.sh /usr/local/bin/build-edition.sh
RUN chmod 755 /usr/local/bin/build-edition.sh

ENTRYPOINT ["/usr/local/bin/build-edition.sh"]
