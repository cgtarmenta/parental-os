FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    ca-certificates \
    debootstrap \
    isolinux \
    live-build \
    rsync \
    squashfs-tools \
    sudo \
    syslinux-common \
    xorriso \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /build
CMD ["lb", "--help"]
