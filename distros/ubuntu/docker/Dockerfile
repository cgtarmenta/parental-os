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
    syslinux-utils \
    xorriso \
  && ln -sf /usr/lib/ISOLINUX/isolinux.bin /usr/share/live/build/bootloaders/isolinux/isolinux.bin \
  && ln -sf /usr/lib/syslinux/modules/bios/vesamenu.c32 /usr/share/live/build/bootloaders/isolinux/vesamenu.c32 \
  && sed -i 's|Check_package chroot/usr/lib/syslinux syslinux-common|Check_package chroot/usr/lib/syslinux syslinux-common\n\t\tCheck_package chroot/usr/lib/ISOLINUX/isolinux.bin isolinux|' /usr/lib/live/build/lb_binary_syslinux \
  && sed -i 's|chroot/usr/bin/rsvg librsvg2-bin|chroot/usr/bin/rsvg-convert librsvg2-bin|g; s|/usr/bin/rsvg - no such file|/usr/bin/rsvg-convert - no such file|g; s|\[ ! -e /usr/bin/rsvg \]|[ ! -e /usr/bin/rsvg-convert ]|g; s|rsvg --format|rsvg-convert --format|g' /usr/lib/live/build/lb_binary_syslinux \
  && sed -i 's|rsvg-convert --format png --height 480 --width 640 splash.svg splash.png|rsvg-convert --format png --height 480 --width 640 --output splash.png splash.svg|g; s|rsvg-convert --format png --height 480 --width 640 "${_TARGET}/splash.svg" "${_TARGET}/splash.png"|rsvg-convert --format png --height 480 --width 640 --output "${_TARGET}/splash.png" "${_TARGET}/splash.svg"|g' /usr/lib/live/build/lb_binary_syslinux \
  && sed -i 's|Chroot chroot "tar xfz /usr/share/gfxboot-theme-ubuntu/bootlogo.tar.gz -C /root/$(basename ${_SOURCE}).tmp"|if [ "${LB_SYSLINUX_THEME}" != "live-build" ]; then Chroot chroot "tar xfz /usr/share/gfxboot-theme-ubuntu/bootlogo.tar.gz -C /root/$(basename ${_SOURCE}).tmp"; fi|' /usr/lib/live/build/lb_binary_syslinux \
  && sed -i 's|tar xfz /usr/share/gfxboot-theme-ubuntu/bootlogo.tar.gz -C ${_TARGET}|if [ "${LB_SYSLINUX_THEME}" != "live-build" ]; then tar xfz /usr/share/gfxboot-theme-ubuntu/bootlogo.tar.gz -C ${_TARGET}; fi|' /usr/lib/live/build/lb_binary_syslinux \
  && sed -i 's|^tmpdir="$(mktemp -d)"$|if [ "${LB_SYSLINUX_THEME}" != "live-build" ]\nthen\n\ttmpdir="$(mktemp -d)"|; s|^rm -rf "$tmpdir"$|rm -rf "$tmpdir"\nfi|' /usr/lib/live/build/lb_binary_syslinux \
  && sed -i 's|Check_package chroot/usr/bin/isohybrid syslinux|Check_package chroot/usr/bin/isohybrid syslinux-utils|' /usr/lib/live/build/lb_binary_iso \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /build
CMD ["lb", "--help"]
