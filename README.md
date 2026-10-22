# ArgosOpen Agent

EC2 인스턴스에 모니터링 에이전트(Grafana Alloy)를 설치하는 스크립트.

호스트 OS 메트릭(CPU/MEM/Disk/Network) + 컨테이너 메트릭 + 시스템/컨테이너 로그 + 명령 실행 감사를
수집해 **중앙 수집 서버로 push**합니다.

```
[EC2 × N]  Alloy(agent) ──push──▶  [중앙 수집 서버]
```

이 저장소는 **에이전트 노드만** 다룹니다. 중앙 서버 구성은 범위 밖이며,
에이전트 입장에서 필요한 건 push 대상 엔드포인트 두 개뿐입니다.

```
MIMIR_ENDPOINT=http://<중앙노드_IP>:9009/api/v1/push      # 메트릭 (Prometheus remote_write 호환)
LOKI_ENDPOINT=http://<중앙노드_IP>:3100/loki/api/v1/push  # 로그  (Loki push API 호환)
```

이 두 주소만 받으면 동작하므로, 중앙이 어떻게 구성돼 있든 상관없습니다.

---

## 설계 — 설정은 파일, 스크립트는 노드 작업

**`compose/` 안의 파일이 유일한 정답(single source of truth)입니다.**
`init`은 그 파일들을 **복사만** 하고, 내용을 만들어내지 않습니다.

| 무엇을 바꾸려면 | 어디를 고치나 |
|----------------|--------------|
| 컨테이너 구성 (이미지, 볼륨, 포트, healthcheck) | `compose/docker-compose.yml` |
| 수집 항목 (메트릭, 로그, 라벨, scrape 주기) | `compose/config.alloy` |
| 노드에 필요한 사전 작업 (패키지 설치, 커널 설정, 감사 스크립트) | `init` |



지금은 이렇게 바뀌었습니다.

```bash
# 현재 방식
install_files() {
  install -m 644 "$COMPOSE_SRC/docker-compose.yml" "$d/docker-compose.yml"
  install -m 644 "$COMPOSE_SRC/config.alloy"       "$d/config.alloy"
  apply_log_filter "$d"      # 치환 토큰만 처리
}
```

`compose/docker-compose.yml`과 설치본은 **바이트 단위로 동일**합니다.
스크립트가 내용에 관여하지 않습니다.

### 치환 토큰

`config.alloy`에는 대문자+밑줄 형태의 치환 토큰 두 개가 있습니다.
`init`이 `LOG_KEEP_REGEX` 값에 따라 로그 수신자와 필터 블록으로 바꿔 넣습니다.
필터를 안 쓰면 기본 수신자와 빈 줄로 치환됩니다.

**직접 편집할 때 그 토큰을 지우지 마세요.** 치환에 실패하면 `init`이 중단됩니다
— 잘못된 설정이 조용히 배포되는 것보다 낫기 때문입니다.

### 앞으로 노드에 설정이 더 필요해지면

`init`에 단계를 추가하고, 그에 맞춰 `compose/` 파일도 함께 고칩니다.
**설정 내용을 `init`에 heredoc으로 되돌리지 마세요.** 위 세 문제가 그대로 돌아옵니다.

---

## 빠른 시작

```bash
# 저장소를 통째로 받아서 실행 (compose/ 파일이 필요하므로 curl | bash 불가)
git clone <repo> && cd ArgosOpenAgent

sudo ./init agent <중앙노드_IP>          # 설치만 (기동 안 함)
sudo ./init agent <중앙노드_IP> --up     # 설치 + 기동

# 예시
sudo ./init agent 10.0.0.10 --up
```

git·Docker/Compose 설치 → `compose/` 파일 복사 → `.env` 생성 → cmdaudit 설치까지 수행합니다.
기본값은 **기동하지 않음**이라, 파일을 확인한 뒤 직접 올리면 됩니다.

```bash
ls -la /opt/argos-agent/
vi /opt/argos-agent/config.alloy

cd /opt/argos-agent && sudo docker compose up -d
```

### 설정을 바꾼 뒤 재배포

고칠 곳이 두 군데입니다.

| 고칠 위치 | 언제 쓰나 | `init` 재실행하면 |
|----------|----------|-----------------|
| `/opt/argos-agent/config.alloy` (노드의 배포본) | 이 노드에서만 값 하나 바꿔볼 때 | 원본으로 덮어써짐 |
| `compose/config.alloy` (저장소의 원본) | 모든 노드에 계속 적용할 때 | 유지 (이쪽이 배포본을 덮어씀) |

```bash
vi compose/config.alloy                        # 수집 항목 수정
KEEP_ENV=1 sudo ./init agent 10.0.0.10         # .env 는 보존하고 파일만 갱신
cd /opt/argos-agent && sudo docker compose restart
```

### init 없이 수동 배포

Docker가 이미 있고 스크립트를 안 쓰고 싶다면:

```bash
sudo mkdir -p /opt/argos-agent
sudo cp compose/docker-compose.yml compose/config.alloy /opt/argos-agent/
sudo cp compose/.env.example /opt/argos-agent/.env
sudo vi /opt/argos-agent/.env   # 엔드포인트·노드 식별자 채우기

# config.alloy 의 치환 토큰을 직접 처리 (필터를 안 쓸 경우)
sudo sed -i 's/__DOCKER_SINK__/loki.write.loki.receiver/; /^__FILTER_BLOCK__$/d' \
  /opt/argos-agent/config.alloy

cd /opt/argos-agent && sudo docker compose up -d
```

## 수집 항목

| 구분 | 대상 | 도구 |
|------|------|------|
| 메트릭 | CPU, 메모리, 디스크, 네트워크 | node_exporter (Alloy 내장) |
| 메트릭 | 컨테이너 CPU/MEM/NET | cAdvisor (Alloy 내장) |
| 로그 | 컨테이너 stdout/stderr | docker.sock tail |
| 로그 | systemd journal (SSH, sudo 등) | journald |
| 감사 | 명령 실행 기록 | cmdaudit (PROMPT_COMMAND → journald) |

모든 시계열·로그에 `instance`(고유 식별자)와 `node`(사람이 읽는 이름) 라벨이 붙습니다.
호스트 메트릭은 `job=node`로 정규화됩니다.

## 프로젝트 구조

```
├── init                        # 노드 부트스트랩: ./init agent <IP>
├── compose/                    # ★ 실제 배포되는 파일 (여기가 정답)
│   ├── docker-compose.yml      # Alloy + autoheal
│   ├── config.alloy            # Alloy 수집 설정
│   └── .env.example            # 환경변수 템플릿
└── README.md
```

`init`이 `/opt/argos-agent/`에 만드는 것:

```
├── docker-compose.yml          # compose/ 에서 복사 (내용 동일)
├── config.alloy                # compose/ 에서 복사 + 치환 토큰 처리
└── .env                        # init 이 생성 (엔드포인트·노드 식별자, 0600)
```

## 컨테이너 구성

| 컨테이너 | 이미지 | 역할 |
|---------|--------|------|
| `argos-alloy` | `grafana/alloy:v1.18.0` | 메트릭·로그 수집 후 push. healthcheck: `:12345/-/ready` |
| `argos-autoheal` | `willfarrell/autoheal@sha256:b9b7a5e…` | healthcheck 실패 시 자동 재시작 |

`latest`를 쓰지 않고 고정합니다 — 노드마다 다른 버전이 깔리는 걸 막기 위함입니다.
Alloy 버전이 다르면 수집 항목·라벨이 미묘하게 어긋날 수 있습니다.

autoheal 만 태그가 아니라 digest 로 고정했습니다. 버전 태그가 2021년 `1.2.0` 에서 멈춰 있고
`latest` 는 계속 갱신되는(사실상 main) 이미지라, "지금 돌고 있는 내용"을 그대로 굳히려면
digest 가 유일한 방법입니다.

업그레이드는 `compose/docker-compose.yml`을 고쳐 커밋으로 남깁니다.
`docker compose pull`만으로는 버전이 올라가지 않습니다.

`restart: unless-stopped`는 프로세스가 죽었을 때만 살립니다. Alloy가 살아는 있지만
수집이 멈춘 상태는 못 잡기 때문에 autoheal을 따로 둡니다.

## 관리

```bash
cd /opt/argos-agent

docker compose ps            # 상태 확인
docker compose logs -f       # 로그
docker compose restart       # 재시작
docker compose down          # 중지
docker compose pull && docker compose up -d  # 업데이트

curl -s localhost:12345/-/ready     # Alloy 헬스
```

## 옵션

| 플래그 | 기본 | 설명 |
|--------|------|------|
| `--up` | — | 마지막에 `docker compose up -d` 까지 수행 |
| `--no-up` | ✔ | 기동하지 않음 (기본값, 명시용) |

| 환경변수 | 기본 | 설명 |
|---------|------|------|
| `BASE_DIR` | `/opt/argos-agent` | 설치 경로 |
| `COMPOSE_UP` | `0` | `1`이면 `--up`과 동일 |
| `INSTALL_GIT` | `1` | git 설치 |
| `INSTALL_DOCKER` | `1` | Docker/Compose 설치 |
| `COMPOSE_VERSION` | `v2.32.4` | Compose 플러그인 버전 |
| `INSTALL_CMD_AUDIT` | `1` | 명령 실행 감사 설치 |
| `INSTANCE_ID` | EC2 instance-id | 없으면 hostname |
| `NODE_NAME` | EC2 Name 태그 | 없으면 `INSTANCE_ID` |
| `KEEP_ENV` | `0` | `1`이면 기존 `.env` 덮어쓰지 않음 |
| `COMPOSE_SRC` | `<스크립트>/compose` | 설정 원본 경로 |
| `LOG_KEEP_REGEX` | (없음) | 컨테이너 로그 필터 |

```bash
INSTALL_DOCKER=0 sudo ./init agent 10.0.0.10          # Docker 이미 있음
BASE_DIR=/home/ec2-user/agent sudo ./init agent 10.0.0.10
```

### 컨테이너 로그 필터

```bash
LOG_KEEP_REGEX="(?i)(error|warn|fatal)" sudo ./init agent 10.0.0.10
```

정규식에 **매칭되지 않는** 컨테이너 로그 줄을 Alloy 단계에서 버립니다.
Go 정규식(RE2)에는 부정 룩어헤드가 없어 not-match로 뒤집어 drop하는 방식입니다.

- **journald에는 적용되지 않습니다.** SSH 로그인·sudo·계정 변경은 전부 INFO 레벨이라
  `error|warn`로 거르면 보안 감사 로그가 통째로 사라집니다.
- 스택트레이스는 `stage.multiline`으로 먼저 묶은 뒤 필터링합니다. 순서가 뒤바뀌면
  첫 줄만 남고 `at com.foo...` 본문이 전부 버려집니다.
- 버려진 줄 수: `curl -s localhost:12345/metrics | grep loki_process_dropped_lines_total`
- **버려진 줄은 복구할 수 없습니다.** 장애 원인은 보통 에러 "직전"의 INFO에 있으니,
  특정 컨테이너가 폭주하는 게 확인된 경우가 아니면 켜지 마세요.

## 운영 환경 전환 시 변경 사항

PoC에서 실제 운영으로 전환할 때 확인해야 할 항목:

| 항목 | 파일 | 현재 (PoC) | 운영 시 변경 |
|------|------|-----------|------------|
| 클러스터 라벨 | `compose/config.alloy` 85, 124번 줄 | `cluster = "poc"` | 고객사/환경에 맞게 변경 (예: `"uc"`, `"prod"`) |
| 파일시스템 수집 제외 | `compose/config.alloy` 32번 줄 `fs_types_exclude` | `nfs\|nfs4` 제외 해제됨 | EFS 사용 시 `nfs4`가 제외 목록에 없는지 확인 |
| Alloy 이미지 버전 | `compose/docker-compose.yml` | `grafana/alloy:v1.18.0` | 운영 안정 버전으로 고정 유지 |
| 로그 필터 | `LOG_KEEP_REGEX` 환경변수 | 미설정 (전량 수집) | 필요 시 설정 |

```bash
# 클러스터 라벨 변경 예시
sed -i 's/cluster = "poc"/cluster = "uc"/' compose/config.alloy
KEEP_ENV=1 sudo ./init agent <중앙노드_IP>
cd /opt/argos-agent && sudo docker compose restart
```

> **주의**: 클러스터 라벨을 변경하면 변경 이전 데이터는 기존 라벨(`poc`)로 남아있습니다.
> Grafana 대시보드에서 `cluster` 필터를 사용하는 경우 양쪽 값을 모두 포함하도록 설정하거나,
> 전환 시점을 기준으로 대시보드 시간 범위를 맞추세요.

## 요구사항

- Linux (dnf / yum / apt 중 하나)
- root 권한 (`sudo`)
- 중앙 수집 서버로의 아웃바운드: **TCP 9009**(메트릭), **TCP 3100**(로그)
