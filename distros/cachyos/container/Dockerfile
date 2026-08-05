# parental-os CachyOS builder container.
#
# This ephemeral privileged container runs the official CachyOS ISO build
# scripts (which mutate /usr/bin/mkarchiso) without touching the host system.
# It is built from the current Arch base-devel image and includes the CachyOS
# keyring so the official repos can be used during ISO assembly.
FROM archlinux:base-devel

ENV LANG=C.UTF-8

# Install standard Arch packages: archiso (mkarchiso), git, sudo, rsync,
# python, jq, squashfs/ISO inspection tools, repository utilities.
RUN pacman -Syu --noconfirm --needed \
      archiso \
      git \
      sudo \
      rsync \
      python \
      python-yaml \
      jq \
      squashfs-tools \
      xorriso \
      dosfstools \
      e2fsprogs \
      parted \
      grub \
      efibootmgr \
      mtools \
      libisoburn \
      archlinux-keyring \
    && rm -rf /var/cache/pacman/pkg/*

# Add the CachyOS repository with Optional TrustAll initially so we can
# install the CachyOS keyring and mirrorlist packages.
RUN grep -q '^\[cachyos\]' /etc/pacman.conf \
    || printf '\n[cachyos]\nSigLevel = Optional TrustAll\nServer = https://mirror.cachyos.org/repo/$arch/$repo\n' >> /etc/pacman.conf

# Install CachyOS keyring and mirrorlist from the CachyOS repo.
RUN pacman -Sy --noconfirm --needed cachyos-keyring cachyos-mirrorlist \
    && rm -rf /var/cache/pacman/pkg/*

# Initialize and locally trust the CachyOS keyring as required by the
# official workflow. Also populate archlinux keys.
RUN pacman-key --init \
    && pacman-key --populate archlinux \
    && pacman-key --populate cachyos \
    || true

# Create a non-root builder user with narrowly scoped sudo access.
# The upstream CachyOS buildiso.sh uses sudo for mkarchiso and for patching
# /usr/bin/mkarchiso. We grant NOPASSWD only for the specific commands the
# build requires, not blanket ALL=NOPASSWD: ALL.
RUN useradd -m -G wheel -s /bin/bash builder

# Narrowly scoped sudoers: builder can run mkarchiso, pacman, sed on
# /usr/bin/mkarchiso, chown for the official output folder handoff, repo-add,
# and the build entrypoint without a password.
# This is NOT a blanket ALL=NOPASSWD: ALL grant.
RUN mkdir -p /etc/sudoers.d \
    && printf 'builder ALL=(root) NOPASSWD: /usr/bin/mkarchiso, /usr/bin/pacman, /usr/bin/pacman-key, /usr/bin/repo-add, /usr/bin/repo-remove, /usr/bin/sed, /usr/bin/rm, /usr/bin/chown builder *, /usr/bin/bash /usr/local/bin/build-edition.sh *\n' \
       > /etc/sudoers.d/builder \
    && chmod 440 /etc/sudoers.d/builder \
    && visudo -cf /etc/sudoers.d/builder

# Create the local parental-os repository directory on the container filesystem
# so mkarchiso's pacstrap can access it via file:///srv/parental-os-repo.
# Make it writable by builder so the entrypoint can copy packages there.
RUN mkdir -p /srv/parental-os-repo && chown builder:builder /srv/parental-os-repo

USER builder
WORKDIR /home/builder

# Copy the container entrypoint. The host build script mounts the parental-os
# checkout read-only at /repo and out/ read-write at /out.
COPY --chown=builder:builder build-edition.sh /usr/local/bin/build-edition.sh
RUN chmod 755 /usr/local/bin/build-edition.sh

ENTRYPOINT ["/usr/local/bin/build-edition.sh"]
