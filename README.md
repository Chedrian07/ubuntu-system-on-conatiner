ubuntu-system-docker
====================

English
-------
Run real Ubuntu cloud (cloud-init) VMs inside Docker using QEMU. Each service (u1604/u1804/u2004/u2204/u2404) is a container that boots a matching Ubuntu guest with a static IP behind a TAP/NAT bridge. You can watch the serial console and SSH via the container’s IP.

Features
- One-command up via `run.sh`. Generates `compose.gen.yml` for the releases you choose.
- Supports Xenial → Noble (16.04/18.04/20.04/22.04/24.04).
- Deterministic MAC per service and static guest IP `172.30.0.2/24`.
- cloud-init seed with default user `ubuntu`/`ubuntu` (password auth enabled), automatic growpart/apt update.
- Cleans iptables rules on shutdown.

Requirements
- Docker with Compose v2.
- Host must allow `/dev/net/tun` and `CAP_NET_ADMIN` inside the container.
- ~20GB per VM by default (sparse qcow2 grows on use).

Quick start
```
./run.sh --versions jammy --foreground --build
```

More examples
```
# All supported releases
./run.sh --versions all --build

# Two versions, custom resources
./run.sh --versions 2204,2404 --cpus 4 --memory 8g --disk 40 --build

# Background run
./run.sh --versions jammy
```

CLI options
- `--versions`  all | comma list (e.g. `jammy`, `2204,2404`, `xenial,bionic,focal`)
- `--cpus`      number of vCPUs for the VM (and Compose CPU limit)
- `--memory`    container memory limit (e.g. `4g`, `8192m`) → VM RAM auto-converted to MB
- `--disk`      VM disk size in GB (qcow2 resize)
- `--foreground` attach to the serial console
- `--build`     force image build
- `--prefix`    service name prefix (default: `u`) → e.g. `u2204`

How it works (networking)
- The container creates `tap0` (172.30.0.1/24) and starts QEMU with the guest at `172.30.0.2`.
- iptables DNATs **all TCP/UDP destined to the container IP** to the guest (`172.30.0.2`), and MASQUERADEs outbound.
- To SSH from the host, connect to the **container IP** on port 22:
  ```
  docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' u2204
  ssh ubuntu@<container-ip>    # password: ubuntu
  ```

Data layout
```
vmdata-<tag>/
  ├── <codename>-amd64.img   # qcow2 system disk (resized to --disk GB)
  ├── user-data              # cloud-init
  ├── meta-data
  ├── network-config
  └── seed.iso               # regenerated on container start
```

Stop / clean
```
docker compose -f compose.gen.yml down
# remove vmdata-<tag> to recreate from a fresh cloud image
rm -rf vmdata-2204
```

Compatibility & notes
- Ubuntu 18.04 (bionic) netplan cannot parse `routes: to: default`. If you run 18.04, use `to: 0.0.0.0/0` (or `gateway4:`). See comments in `entrypoint.sh`.
- The serial console is attached to container logs; `--foreground` lets you watch the full boot.
- Cloud-init disables `systemd-networkd-wait-online` to avoid long boot stalls.
- Change the default password immediately: `passwd ubuntu`.

—

한국어 (Korean)
---------------
Docker 컨테이너 안에서 QEMU로 **진짜 Ubuntu VM**(cloud‑init)을 실행합니다. 각 서비스(u1604/u1804/u2004/u2204/u2404)는 고정 IP를 가진 게스트를 부팅하며, 컨테이너의 시리얼 콘솔을 보고 컨테이너 IP로 SSH 접속할 수 있습니다.

특징
- `run.sh` 한 번으로 `compose.gen.yml`을 생성하고 실행
- 16.04 ~ 24.04 (Xenial→Noble) 지원
- 서비스별 고정 MAC, 게스트 고정 IP `172.30.0.2/24`
- 기본 계정 `ubuntu/ubuntu`(비밀번호 로그인 허용), 디스크 자동 확장(growpart), `apt update`
- 종료 시 iptables 규칙 정리

요구사항
- Docker (Compose v2)
- 컨테이너에서 `/dev/net/tun` 사용 가능, `CAP_NET_ADMIN` 필요
- VM당 기본 20GB(증가형 qcow2)

빠른 시작
```
./run.sh --versions jammy --foreground --build
```

추가 예시
```
./run.sh --versions all --build
./run.sh --versions 2204,2404 --cpus 4 --memory 8g --disk 40 --build
./run.sh --versions jammy   # 백그라운드 실행
```

CLI 옵션
- `--versions`  all | 콤마 구분 목록 (예: `jammy`, `2204,2404`, `xenial,bionic,focal`)
- `--cpus`      VM vCPU 수(및 Compose CPU 제한)
- `--memory`    컨테이너 메모리 제한 (예: `4g`, `8192m`) → VM RAM은 MB로 자동 변환
- `--disk`      VM 디스크 용량(GB, qcow2 리사이즈)
- `--foreground` 시리얼 콘솔에 attach
- `--build`     이미지 강제 빌드
- `--prefix`    서비스 접두사(기본: `u`) → 예: `u2204`

동작 원리(네트워크)
- 컨테이너가 `tap0(172.30.0.1/24)`를 만들고, 게스트는 `172.30.0.2`로 부팅됩니다.
- 컨테이너 IP로 들어오는 **모든 TCP/UDP**를 DNAT하여 게스트로 전달하고, 외부 트래픽은 MASQUERADE 합니다.
- 호스트에서 SSH 접속:
  ```
  docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' u2204
  ssh ubuntu@<컨테이너-IP>   # 비밀번호: ubuntu
  ```

디렉터리 구조
```
vmdata-<tag>/
  ├── <codename>-amd64.img
  ├── user-data
  ├── meta-data
  ├── network-config
  └── seed.iso
```

정지 / 정리
```
docker compose -f compose.gen.yml down
rm -rf vmdata-2204   # 새 이미지로 초기화
```

호환 / 주의
- **Ubuntu 18.04(bionic)** 의 netplan은 `routes: to: default`를 지원하지 않습니다. `to: 0.0.0.0/0`(또는 `gateway4:`) 표기를 사용하세요. 자세한 내용은 `entrypoint.sh` 참고.
- 시리얼 콘솔은 컨테이너 로그로 확인 가능하며 `--foreground`로 부팅 과정을 실시간으로 볼 수 있습니다.
- cloud‑init이 `systemd-networkd-wait-online`을 비활성화하여 부팅 지연을 방지합니다.

License / Credits (optional)
- Ubuntu Cloud Images © Canonical. This project automates local use under the Ubuntu image terms.