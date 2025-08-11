FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive \
    QEMU_AUDIO_DRV=none

WORKDIR /opt/vm

RUN apt-get update && apt-get install -y --no-install-recommends \
    qemu-system-x86 qemu-utils cloud-image-utils \
    iproute2 iptables iputils-ping curl ca-certificates \
  && rm -rf /var/lib/apt/lists/*

# 실행 스크립트
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# VM 디스크/시드 보존
VOLUME ["/vm"]

ENTRYPOINT ["/entrypoint.sh"]