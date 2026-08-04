FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    debootstrap \
    fdisk \
    gnupg \
    isolinux \
    live-boot \
    live-build \
    live-config \
    live-tools \
    rsync \
    squashfs-tools \
    sudo \
    syslinux-common \
    xorriso \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /build
CMD ["lb", "--help"]
