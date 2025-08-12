#!/usr/bin/env bash
set -euo pipefail

# 기본값
VERSIONS="all"          # all | xenial,bionic,focal,jammy,noble | 1604,1804,2004,2204,2404 혼용 가능
CPUS="2"                # 컨테이너 CPU 제한 (예: 2)
MEMORY="4g"             # 컨테이너 메모리 제한 (예: 4g / 4096m)
DISK="20"               # VM 디스크(GB)
ACCEL="tcg,thread=multi" # QEMU accelerator 기본값
CPU="qemu64"            # QEMU CPU 모델 기본값
MACHINE=""              # QEMU machine 타입 기본값 (비어있으면 기본 pc 사용)
FOREGROUND=0            # 1이면 attach 실행
BUILD=0                 # 1이면 --build
PREFIX="u"              # 서비스 접두사 (u2204 등)
GEN_YAML="compose.gen.yml"

usage() {
  cat <<EOF
Usage: $0 [options]

Options:
  --versions   all | list (comma)  예: jammy / noble / 2204,2404 / xenial,bionic,focal
  --cpus       N                   예: 2
  --memory     SIZE                예: 4g, 8192m
  --disk       GB                  예: 20
  --accel      ACCEL               예: tcg,thread=multi (기본)
  --cpu        CPU_MODEL           예: qemu64 (기본)
  --machine    MACHINE_TYPE        예: q35 (기본 없음)
  --foreground                      포그라운드 실행(attach)
  --build                           빌드 강제
  --prefix     NAME                서비스 접두사(기본: u)
  -h, --help

예시:
  $0 --versions jammy --foreground
  $0 --versions all --cpus 2 --memory 4g --disk 20 --build
EOF
}

# 인자 파싱
while [[ $# -gt 0 ]]; do
  case "$1" in
    --versions) VERSIONS="$2"; shift 2;;
    --cpus) CPUS="$2"; shift 2;;
    --memory) MEMORY="$2"; shift 2;;
    --disk) DISK="$2"; shift 2;;
    --accel) ACCEL="$2"; shift 2;;
    --cpu) CPU="$2"; shift 2;;
    --machine) MACHINE="$2"; shift 2;;
    --foreground) FOREGROUND=1; shift 1;;
    --build) BUILD=1; shift 1;;
    --prefix) PREFIX="$2"; shift 2;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown arg: $1"; usage; exit 1;;
  esac
  done

# 버전 정규화 및 태그 함수 정의
norm_ver() {
  local v="$1"
  v="$(echo "$v" | tr 'A-Z' 'a-z')"
  case "$v" in
    all) echo "xenial, bionic, focal, jammy, noble"; return 0;;
    xenial|16|16.04|1604|u1604) echo "xenial"; return 0;;
    bionic|18|18.04|1804|u1804) echo "bionic"; return 0;;
    focal|20|20.04|2004|u2004)  echo "focal";  return 0;;
    jammy|22|22.04|2204|u2204)  echo "jammy";  return 0;;
    noble|24|24.04|2404|u2404)  echo "noble";  return 0;;
    *) echo "$v";;
  esac
}

to_tag() {
  case "$1" in
    xenial) echo "1604";;
    bionic) echo "1804";;
    focal)  echo "2004";;
    jammy)  echo "2204";;
    noble)  echo "2404";;
    *) echo "0000";;
  esac
}

# 버전 정규화 및 태그 함수 정의 (정의 위치 조정)
norm_ver() {
  local v="$1"
  v="$(echo "$v" | tr 'A-Z' 'a-z')"
  case "$v" in
    all) echo "xenial, bionic, focal, jammy, noble"; return 0;;
    xenial|16|16.04|1604|u1604) echo "xenial"; return 0;;
    bionic|18|18.04|1804|u1804) echo "bionic"; return 0;;
    focal|20|20.04|2004|u2004)  echo "focal";  return 0;;
    jammy|22|22.04|2204|u2204)  echo "jammy";  return 0;;
    noble|24|24.04|2404|u2404)  echo "noble";  return 0;;
    *) echo "$v";;
  esac
}

to_tag() {
  case "$1" in
    xenial) echo "1604";;
    bionic) echo "1804";;
    focal)  echo "2004";;
    jammy)  echo "2204";;
    noble)  echo "2404";;
    *) echo "0000";;
  esac
}

# 메모리를 MB로 변환(QEMU에 넘길 값)
mem_to_mb() {
  local s="$1"
  case "$s" in
    *g|*G)
      local n="${s%[gG]}"
      echo $(( n * 1024 ))
      ;;
    *m|*M)
      local n="${s%[mM]}"
      echo $(( n ))
      ;;
    *)
      # 그냥 숫자면 MB로 가정
      echo "$s"
      ;;
  esac
}

VM_RAM_MB="$(mem_to_mb "$MEMORY")"

# Compose YAML 시작
echo "services:" > "$GEN_YAML"

emit_service_yaml() {
  local code="$1"
  local tag
  tag="$(to_tag "$code")"
  local svc="${PREFIX}${tag}"

  # 충돌 없는 MAC: 52:54:00:XX:YY:00 (예: jammy=22:04)
  local mac_hex="$(echo "$tag" | sed -E 's/^([0-9]{2})([0-9]{2})$/\1:\2/')"
  local vm_mac="52:54:00:${mac_hex}:00"

  mkdir -p "./vmdata-${tag}"

  cat >> "$GEN_YAML" <<EOF
  ${svc}:
    build: .
    container_name: ${svc}
    environment:
      - UBUNTU_CODENAME=${code}
      - DISK_SIZE_GB=${DISK}
      - VM_MAC=${vm_mac}
      - VM_VCPUS=${CPUS}
      - VM_RAM_MB=${VM_RAM_MB}
      - QEMU_ACCEL=${ACCEL}
      - QEMU_CPU=${CPU}
      - QEMU_MACHINE=${MACHINE}
    cap_add:
      - NET_ADMIN
    devices:
      - /dev/net/tun
    sysctls:
      net.ipv4.ip_forward: "1"
    cpus: "${CPUS}"
    mem_limit: "${MEMORY}"
    volumes:
      - ./vmdata-${tag}:/vm
    restart: unless-stopped
EOF
}


# VERSIONS 해석
resolved=""
IFS=',' read -r -a arr <<< "$(echo "$VERSIONS" | sed 's/ //g')"
tmp_list=()
for raw in "${arr[@]}"; do
  n="$(norm_ver "$raw")"
  if [[ "$n" == "xenial, bionic, focal, jammy, noble" ]]; then
    tmp_list+=(xenial bionic focal jammy noble)
  else
    tmp_list+=("$n")
  fi
done

# 중복 제거
uniq_list=()
for v in "${tmp_list[@]}"; do
  skip=0
  if [[ ${#uniq_list[@]} -gt 0 ]]; then
    for u in "${uniq_list[@]}"; do
      [[ "$u" == "$v" ]] && skip=1 && break
    done
  fi
  [[ $skip -eq 0 ]] && uniq_list+=("$v")
done

# 서비스 블록 생성
for code in "${uniq_list[@]}"; do
  case "$code" in
    xenial|bionic|focal|jammy|noble) emit_service_yaml "$code";;
    *) echo "경고: 알 수 없는 버전 스킵 → $code" >&2;;
  esac
done

# 네트워크(기본 브리지)
cat >> "$GEN_YAML" <<'EOF'

networks:
  default:
    driver: bridge
EOF

echo "[INFO] compose 파일 생성: $GEN_YAML"
echo "----------------------------------------"
sed -n '1,200p' "$GEN_YAML" || true
echo "----------------------------------------"

# 실행
set +e
if [[ $BUILD -eq 1 && $FOREGROUND -eq 1 ]]; then
  docker compose -f "$GEN_YAML" up --build
elif [[ $BUILD -eq 1 ]]; then
  docker compose -f "$GEN_YAML" up -d --build
elif [[ $FOREGROUND -eq 1 ]]; then
  docker compose -f "$GEN_YAML" up
else
  docker compose -f "$GEN_YAML" up -d
fi
rc=$?
set -e
exit $rc