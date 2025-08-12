#!/usr/bin/env bash
set -euo pipefail
# ENG : Default parameters
# KOR : 기본 파라미터
VM_DIR="/vm"
# ENG : Supported Ubuntu codenames (xenial/bionic/focal/jammy/noble)
# KOR : xenial/bionic/focal/jammy/noble
UBUNTU_CODENAME="${UBUNTU_CODENAME:-jammy}"
# ENG : Disk size for qemu-img resize (GB)
# KOR : qemu-img resize 용량(GB)
DISK_SIZE_GB="${DISK_SIZE_GB:-20}"
# ENG : Number of QEMU virtual CPUs
# KOR : QEMU vCPU 수
VM_VCPUS="${VM_VCPUS:-2}"
# ENG : QEMU RAM size in MB
# KOR : QEMU RAM(MB)
VM_RAM_MB="${VM_RAM_MB:-4096}"
# ENG : Provided by run.sh (unique per service)
# KOR : run.sh에서 내려줌(서비스별 고유)
VM_MAC="${VM_MAC:-52:54:00:22:04:00}"
# ENG : QEMU accelerator
# KOR : QEMU 가속기
QEMU_ACCEL="${QEMU_ACCEL:-tcg,thread=multi}"
# ENG : QEMU CPU model
# KOR : QEMU CPU 모델
QEMU_CPU="${QEMU_CPU:-qemu64}"
# ENG : QEMU machine type (optional)
# KOR : QEMU 머신 타입 (선택)
QEMU_MACHINE="${QEMU_MACHINE:-}"

# ENG : Internal guest network (isolated per container namespace)
# KOR : 내부 게스트 네트 (컨테이너 네임스페이스마다 독립)
SUBNET="172.30.0.0/24"
TAP_DEV="tap0"
TAP_IP="172.30.0.1/24"
GUEST_IP="172.30.0.2"
GUEST_NETMASK="24"
GATEWAY="172.30.0.1"

IMG="${VM_DIR}/${UBUNTU_CODENAME}-amd64.img"
SEED="${VM_DIR}/seed.iso"
USER_DATA="${VM_DIR}/user-data"
META_DATA="${VM_DIR}/meta-data"
NET_CFG="${VM_DIR}/network-config"

mkdir -p "${VM_DIR}"

# ENG : Check container IP
# KOR : 컨테이너 IP 확인
CONT_IP="$(ip -4 addr show dev eth0 | awk '/inet /{print $2}' | cut -d/ -f1 | head -n1 || true)"
if [[ -z "${CONT_IP}" ]]; then
  echo "[FATAL] 컨테이너 IP를 찾지 못했습니다."
  exit 1
fi
echo "[INFO] Container IP = ${CONT_IP}"

# ENG : IP forwarding (already enabled via container sysctls; ignore failures)
# KOR : IP 포워딩 (컨테이너 sysctls로 이미 켜두지만, 실패해도 무시)
sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true

# ENG : Create TAP device
# KOR : TAP 만들기
if ! ip link show "${TAP_DEV}" >/dev/null 2>&1; then
  ip tuntap add dev "${TAP_DEV}" mode tap
fi
ip addr flush dev "${TAP_DEV}" || true
ip addr add "${TAP_IP}" dev "${TAP_DEV}"
ip link set "${TAP_DEV}" up

# ENG : Initialize & reapply iptables rules
# KOR : iptables 규칙 초기화 & 재적용
iptables -t nat -D PREROUTING -d "${CONT_IP}" -p tcp -j DNAT --to-destination "${GUEST_IP}" 2>/dev/null || true
iptables -t nat -D PREROUTING -d "${CONT_IP}" -p udp -j DNAT --to-destination "${GUEST_IP}" 2>/dev/null || true
iptables -t nat -D POSTROUTING -s "${SUBNET}" ! -d "${SUBNET}" -j MASQUERADE 2>/dev/null || true
iptables -D FORWARD -i eth0 -o "${TAP_DEV}" -d "${GUEST_IP}" -j ACCEPT 2>/dev/null || true
iptables -D FORWARD -i "${TAP_DEV}" -o eth0 -s "${GUEST_IP}" -j ACCEPT 2>/dev/null || true

iptables -t nat -A PREROUTING -d "${CONT_IP}" -p tcp -j DNAT --to-destination "${GUEST_IP}"
iptables -t nat -A PREROUTING -d "${CONT_IP}" -p udp -j DNAT --to-destination "${GUEST_IP}"
iptables -t nat -A POSTROUTING -s "${SUBNET}" ! -d "${SUBNET}" -j MASQUERADE
iptables -A FORWARD -i eth0 -o "${TAP_DEV}" -d "${GUEST_IP}" -j ACCEPT
iptables -A FORWARD -i "${TAP_DEV}" -o eth0 -s "${GUEST_IP}" -j ACCEPT

cleanup() {
  echo "[INFO] Cleaning up iptables rules..."
  iptables -t nat -D PREROUTING -d "${CONT_IP}" -p tcp -j DNAT --to-destination "${GUEST_IP}" 2>/dev/null || true
  iptables -t nat -D PREROUTING -d "${CONT_IP}" -p udp -j DNAT --to-destination "${GUEST_IP}" 2>/dev/null || true
  iptables -t nat -D POSTROUTING -s "${SUBNET}" ! -d "${SUBNET}" -j MASQUERADE 2>/dev/null || true
  iptables -D FORWARD -i eth0 -o "${TAP_DEV}" -d "${GUEST_IP}" -j ACCEPT 2>/dev/null || true
  iptables -D FORWARD -i "${TAP_DEV}" -o eth0 -s "${GUEST_IP}" -j ACCEPT 2>/dev/null || true
  ip link set "${TAP_DEV}" down || true
  ip tuntap del dev "${TAP_DEV}" mode tap || true
}
trap cleanup EXIT

# ENG : Download cloud image
# KOR : 클라우드 이미지 다운로드
fetch_cloud_img() {
  local code="$1" out="$2"
  local base="${code}-server-cloudimg-amd64.img"
  # ENG : Possible URL candidates (tried sequentially)
  # KOR : 가능한 URL 후보들(순차 시도)
  urls=(
    "https://cloud-images.ubuntu.com/${code}/current/${base}"
    "https://cloud-images.ubuntu.com/releases/${code}/release/${base}"
    "https://cloud-images.ubuntu.com/legacy-releases/${code}/release/${base}"
  )
  for u in "${urls[@]}"; do
    echo "[INFO] Trying: $u"
    if curl -fL -o "${out}.download" "$u"; then
      mv "${out}.download" "${out}"
      return 0
    fi
  done
  return 1
}

if [[ ! -f "${IMG}" ]]; then
  echo "[INFO] Downloading Ubuntu (${UBUNTU_CODENAME}) amd64 cloud image..."
  if ! fetch_cloud_img "${UBUNTU_CODENAME}" "${IMG}"; then
    echo "[FATAL] 이미지 다운로드 실패: ${UBUNTU_CODENAME}"
    exit 1
  fi
  echo "[INFO] Resizing disk to ${DISK_SIZE_GB}G..."
  qemu-img resize "${IMG}" "${DISK_SIZE_GB}G"
fi

# ENG : Generate cloud-init seed
# KOR : cloud-init seed 생성
cat > "${USER_DATA}" <<'EOF'
#cloud-config
users:
  - name: ubuntu
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: false
    plain_text_passwd: ubuntu
ssh_pwauth: true
chpasswd: { expire: false }
package_update: true
package_upgrade: true
growpart:
  mode: auto
  devices: ['/']
  ignore_growroot_disabled: false
runcmd:
  - systemctl disable --now systemd-networkd-wait-online.service || true
EOF

cat > "${META_DATA}" <<EOF
instance-id: iid-${UBUNTU_CODENAME}
local-hostname: ${UBUNTU_CODENAME}
EOF

# ENG : Version-specific network configuration (v1: xenial, v2: bionic and above)
# KOR : 버전별 네트워크 설정(v1: xenial, v2: bionic~)
if [[ "${UBUNTU_CODENAME}" == "xenial" ]]; then
  # ENG : network-config v1 (ifupdown)
  # KOR : network-config v1 (ifupdown)
  cat > "${NET_CFG}" <<EOF
version: 1
config:
  - type: physical
    name: eth0
    mac_address: "${VM_MAC}"
    subnets:
      - type: static
        address: ${GUEST_IP}/${GUEST_NETMASK}
        gateway: ${GATEWAY}
        dns_nameservers:
          - 1.1.1.1
          - 8.8.8.8
EOF
else
  # ENG : netplan (v2)
  # KOR : netplan (v2)
# ENG : Default route notation varies by version
# KOR : 버전에 따라 default route 표기 다르게
  if [[ "${UBUNTU_CODENAME}" == "bionic" || "${UBUNTU_CODENAME}" == "focal" ]]; then
    TO_DEFAULT="0.0.0.0/0"
  else
    TO_DEFAULT="default"
  fi

  cat > "${NET_CFG}" <<EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    nic0:
      match:
        macaddress: "${VM_MAC}"
      dhcp4: false
      dhcp6: false
      addresses:
        - ${GUEST_IP}/${GUEST_NETMASK}
      routes:
        - to: ${TO_DEFAULT}
          via: ${GATEWAY}
      nameservers:
        addresses: [1.1.1.1,8.8.8.8]
EOF
fi

cloud-localds -N "${NET_CFG}" "${SEED}" "${USER_DATA}" "${META_DATA}"

echo "[INFO] Starting QEMU (${UBUNTU_CODENAME}, x86_64, ${VM_VCPUS} vCPU, ${VM_RAM_MB}MB)..."

# Build QEMU command with optional machine
QEMU_CMD="qemu-system-x86_64 \
  -accel ${QEMU_ACCEL} \
  -cpu ${QEMU_CPU} \
  -smp ${VM_VCPUS} \
  -m ${VM_RAM_MB} \
  -display none \
  -drive if=virtio,file=${IMG},format=qcow2 \
  -drive if=virtio,file=${SEED},format=raw,readonly=on \
  -device virtio-net-pci,netdev=net0,mac=${VM_MAC} \
  -netdev tap,id=net0,ifname=${TAP_DEV},script=no,downscript=no \
  -serial mon:stdio"

if [[ -n "${QEMU_MACHINE}" ]]; then
  QEMU_CMD="${QEMU_CMD} -machine ${QEMU_MACHINE}"
fi

exec ${QEMU_CMD}