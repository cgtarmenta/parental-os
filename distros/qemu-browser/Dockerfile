FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    ca-certificates \
    novnc \
    qemu-system-x86 \
    qemu-utils \
    websockify \
  && rm -rf /var/lib/apt/lists/*

COPY entrypoint.sh /usr/local/bin/qemu-browser-entrypoint
RUN chmod 755 /usr/local/bin/qemu-browser-entrypoint

EXPOSE 8006 2222
ENTRYPOINT ["/usr/local/bin/qemu-browser-entrypoint"]
