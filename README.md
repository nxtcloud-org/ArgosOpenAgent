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

`config.alloy`에는 대문자+밑줄 형태의 치환 토큰이 있습니다.
- 로그 수신자·필터 블록: `init`이 `LOG_KEEP_REGEX` 값에 따라 바꿔 넣습니다. 필터를 안 쓰면 전송량 상한 단계와 빈 줄로 치환됩니다.
- 전송량 상한(rate·burst): `LOG_RATE` / `LOG_BURST` 숫자로 바꿉니다.

`config-files.alloy`·`docker-compose.files.yml`의 토큰은 `LOG_DIRS`로 만든 수집 블록·마운트로 바뀝니다.

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
# 또는 한 번에: KEEP_ENV=1 sudo ./init agent 10.0.0.10 --up
```

`--up` 은 컨테이너를 다시 만듭니다(`--force-recreate`). 예전에는 `docker compose up -d` 만 해서
`config.alloy` 내용이 바뀌어도 돌고 있는 Alloy 가 옛 설정을 계속 썼습니다 — init 을 다시 돌려도
필터·상한이 적용되지 않았습니다(2026-11-09 실측). 읽기 위치는 볼륨에 있어 다시 만들어도 중복·유실이 없고, 중단은 수 초입니다.

### init 없이 수동 배포

Docker가 이미 있고 스크립트를 안 쓰고 싶다면:

```bash
sudo mkdir -p /opt/argos-agent
sudo cp compose/docker-compose.yml compose/config.alloy compose/alloy-start.sh compose/docker-proxy.cfg /opt/argos-agent/
sudo cp compose/.env.example /opt/argos-agent/.env
sudo vi /opt/argos-agent/.env   # 엔드포인트·노드 식별자 채우기

# config.alloy 의 치환 토큰을 직접 처리 (필터를 안 쓸 경우, 전송량 상한 기본값)
sudo sed -i 's/__DOCKER_SINK__/loki.process.docker_limit.receiver/; /^__FILTER_BLOCK__$/d;
             s/__LOG_RATE__/100/g; s/__LOG_BURST__/1000/g' /opt/argos-agent/config.alloy
# 파일 로그(LOG_DIRS)는 수동 배포를 지원하지 않습니다 — init 을 쓰세요.

cd /opt/argos-agent && sudo docker compose up -d
```

## 수집 항목

| 구분 | 대상 | 도구 |
|------|------|------|
| 메트릭 | CPU, 메모리, 디스크, 네트워크 | node_exporter (Alloy 내장) |
| 메트릭 | 컨테이너 CPU/MEM/NET | cAdvisor (Alloy 내장) |
| 로그 | 컨테이너 stdout/stderr | Docker API (읽기 전용 프록시 경유) |
| 로그 | systemd journal (SSH, sudo 등) | journald |
| 감사 | 명령 실행 기록 | cmdaudit (PROMPT_COMMAND → journald) |
| 로그 | 애플리케이션 로그 파일 (설치 옵션 `LOG_DIRS`, 기본 꺼짐) | loki.source.file (별도 컨테이너) |

모든 시계열·로그에 `instance`(고유 식별자)와 `node`(사람이 읽는 이름) 라벨이 붙습니다.
호스트 메트릭은 `job=node`로 정규화됩니다.

### 로그 전송량 상한

모든 로그는 노드에서 초당 줄 수 상한을 걸고 보냅니다. 넘친 줄은 **버립니다**.

| 대상 | 단위 | 기본값 |
|---|---|---|
| 컨테이너 로그 | 컨테이너마다 | 초당 100줄, 순간 1000줄 |
| 애플리케이션 로그 파일 | 파일마다 (스택트레이스는 1건) | 초당 100줄, 순간 1000줄 |
| journald | 노드 전체 | 초당 200줄, 순간 2000줄 (2배) |

```bash
sudo LOG_RATE=200 LOG_BURST=2000 ./init agent 10.0.0.10 --up   # 값 조정
```

- **왜**: 중앙 Loki 는 테넌트가 하나라 수집 한도(기본 초당 4MB)를 모든 노드가 함께 씁니다.
  상한이 없으면 컨테이너 하나가 에러 루프로 쏟아낸 로그를 Alloy 가 버리지 않고 전부 밀어 넣습니다.
  dind 실측(2026-11-09, 1KB 줄을 20초간 최대 속도로 출력):

  | | 상한 없음 (이전) | 상한 있음 (기본값) |
  |---|---|---|
  | 중앙 도착 (측정 시점까지) | 81만 줄, 그 뒤로도 계속 밀려 들어감 | 약 4천 줄로 끝 |
  | 중앙 Loki 의 한도 초과 거부(429) | 25만 건 | 0 |
  | 옆 컨테이너 로그 (1초 1줄 × 90) | 90/90 | 90/90 |
  | 다른 노드의 작은 push 90회 | 89회 성공, 1회 타임아웃 | 90회 성공 |

  다른 노드가 막히는 것까지는 재현되지 않았습니다. 실제 피해는 중앙이 수 GB 를 받아 디스크·S3·조회 부하를
  떠안는 것과, 그 노드의 전송이 수십 분 밀리는 것입니다.
- **폭주한 것만 잘립니다.** 컨테이너·파일마다 따로 세기 때문에, 한 컨테이너가 초당 2000줄을 쏟아내는
  동안에도 옆 컨테이너의 로그는 한 줄도 빠지지 않았습니다(dind 실측: 초당 1줄 120줄 → 120줄 도착).
- 버리지 않고 기다리게 하면 대기열이 밀려 모든 로그가 늦게 도착하므로 버리는 쪽을 택했습니다.
- 필터(`LOG_KEEP_REGEX`)를 쓰면 필터를 통과한 줄만 셉니다.
- 버려진 줄 수 (컨테이너·journald): `curl -s localhost:12345/metrics | grep loki_process_dropped_lines`
  — `loki_process_dropped_lines_by_label_total{label_value="<컨테이너>"}` 로 어느 컨테이너가 잘렸는지 보입니다.
  파일 로그는 `docker exec argos-alloy-files bash -c 'exec 3<>/dev/tcp/127.0.0.1/12345; printf "GET /metrics HTTP/1.0\r\n\r\n" >&3; cat <&3' | grep dropped`

### 애플리케이션 로그 파일 (설치 옵션 `LOG_DIRS`)

앱이 디스크에 직접 쓰는 파일 로그를 중앙 Loki 로 보냅니다. **기본은 꺼져 있고**, 설치할 때 디렉터리를 주면 켜집니다.
환경마다 로그 위치가 다르므로 경로는 옵션으로 받습니다.

켜면 **별도 컨테이너 `argos-alloy-files`** 가 수집합니다. 이 컨테이너에는 지정한 디렉터리만
`/logsrc/<경로>` 에 읽기 전용으로 붙고, 도커 소켓·호스트 `/`·`/var/lib/docker` 는 없습니다.
권한도 root 의 "남의 파일 읽기"(`DAC_READ_SEARCH`) 하나만 남겼습니다.

> **왜 나눴나**: 메인 Alloy 는 cAdvisor 때문에 호스트 `/` 전체를 보고 root 로 돕니다. 같은 컨테이너가
> 로그 파일을 읽으면, 로그 폴더에 쓸 수 있는 앱 계정(또는 앱 취약점으로 들어온 공격자)이
> `x.log -> /etc/shadow` 같은 링크 하나로 root 전용 파일을 중앙 Loki 로 보낼 수 있었습니다.
> Grafana 에 로그인할 수 있는 사람은 누구나 그 내용을 봅니다. 지금은 링크가 컨테이너 안에서 풀려
> 호스트의 다른 파일에 닿지 않습니다(dind 실측: 절대·상대·`/rootfs` 경로 링크 3종 모두 전송 0건).
> 막힌 링크는 Alloy 로그에 `error getting os stat … no such file or directory` 로 10초마다 남습니다 —
> 누군가 로그 폴더에 링크를 심었다는 신호이니 확인하세요.

```bash
sudo LOG_DIRS=/log ./init agent 10.0.0.10 --up
sudo ./init agent 10.0.0.10 --log-dir=/log --log-dir=/data/logs --up   # 여러 개
sudo LOG_DIRS=/log LOG_FILE_EXT=log,out ./init agent 10.0.0.10 --up    # 확장자 지정 (기본 log,out,txt)
```

사람이 대시보드로 보는 용도가 아니라 RCA 봇 등이 LogQL 로 조회하는 원천 데이터입니다. 조회하는 쪽은 아래 형식을 따릅니다.

```
{job="file", node="<노드>", instance="<인스턴스 ID>", app="<앱>", filename="<호스트 경로>"}
```

| 라벨 | 값 |
|---|---|
| `app` | 지정 디렉터리 바로 아래 폴더 이름 (`LOG_DIRS=/log` 일 때 `/log/tomcat/catalina.out` → `tomcat`). 지정 디렉터리 바로 아래 파일은 그 디렉터리 이름 (`/log/app.log` → `log`) |
| `filename` | 호스트 기준 전체 경로 |

- 본문은 원문 그대로. 공백으로 시작하는 줄(Java 스택트레이스 `\tat …`)은 앞 줄에 붙여 한 건으로 보냅니다.
- 대상은 `LOG_FILE_EXT` 확장자만. 압축(`*.gz`)·회전 사본(`catalina.out.1`, `app.log.2026-10-21`)은 보내지 않습니다.
- **켜는 시점에 이미 있던 내용은 보내지 않고**, 그 뒤 추가분과 새로 생긴 파일(첫 줄부터)만 보냅니다.
  `alloy-start.sh` 가 기동 때 기존 파일의 현재 크기를 읽기 위치로 기록합니다. 디렉터리마다 한 번이라,
  나중에 디렉터리를 추가하면 그 디렉터리만 그 시점 기준으로 기록합니다.
- **설치할 때 없는 디렉터리는 빼고 경고합니다.** 디렉터리가 생긴 뒤 `init` 을 다시 실행하면 추가됩니다.
  (없는 경로를 마운트하면 Docker 가 root 소유 빈 디렉터리를 만들어, 나중에 앱이 거기에 로그를 못 씁니다.)
  디렉터리 **안의** 새 파일·하위 폴더는 10초 안에 수집을 시작합니다.
- Alloy 가 뜬 **뒤에** 그 디렉터리 아래에 마운트된 볼륨은 보이지 않습니다 — 그 경우 `docker compose restart alloy-files`.
- `LOG_DIRS` 없이 다시 설치하면 `argos-alloy-files` 를 내립니다(`--up` 시 `--remove-orphans`).
- **이전 버전(메인 Alloy 가 파일을 읽던 구조)에서 올릴 때** 읽기 위치를 넘겨받지 않으므로, 전환 순간
  약 10초 동안 쓰인 줄이 빠집니다(dind 실측: 1초마다 쓴 60줄 중 10줄 누락, 중복 0). 한 번뿐입니다.
- 경로는 절대 경로, 영문·숫자·`. _ - /` 만 받습니다. 서로 겹치는 디렉터리(`/log` 와 `/log/tomcat`)는 거부합니다.

## 프로젝트 구조

```
├── init                        # 노드 부트스트랩: ./init agent <IP>
├── compose/                    # ★ 실제 배포되는 파일 (여기가 정답)
│   ├── docker-compose.yml      # Alloy + docker-proxy
│   ├── config.alloy            # Alloy 수집 설정
│   ├── docker-proxy.cfg        # Docker API 읽기 전용 프록시 설정 (haproxy)
│   ├── docker-compose.files.yml  # 파일 로그 컨테이너 (LOG_DIRS 지정 시 override 로 설치)
│   ├── config-files.alloy      # 파일 로그 수집 설정 (LOG_DIRS 지정 시)
│   ├── alloy-start.sh          # Alloy 기동 래퍼 (파일 로그 첫 읽기 위치 기록)
│   └── .env.example            # 환경변수 템플릿
├── host/                       # 호스트에 설치되는 파일
│   ├── argos-autoheal          # unhealthy 컨테이너 재시작 스크립트 → /usr/local/sbin
│   └── argos-autoheal.{service,timer}  # 30초 주기 systemd 타이머 → /etc/systemd/system
└── README.md
```

`init`이 `/opt/argos-agent/`에 만드는 것:

```
├── docker-compose.yml          # compose/ 에서 복사 (내용 동일)
├── config.alloy                # compose/ 에서 복사 + 치환 토큰 처리
├── alloy-start.sh              # compose/ 에서 복사 (내용 동일)
├── docker-proxy.cfg            # compose/ 에서 복사 (내용 동일)
├── config-files.alloy          # LOG_DIRS 지정 시: compose/ 에서 복사 + 디렉터리별 수집 규칙
├── docker-compose.override.yml # LOG_DIRS 지정 시: docker-compose.files.yml + 디렉터리 마운트 (compose 가 자동으로 함께 읽음)
└── .env                        # init 이 생성 (엔드포인트·노드 식별자, 0600)
```

## 컨테이너 구성

| 컨테이너 | 이미지 | 역할 |
|---------|--------|------|
| `argos-alloy` | `grafana/alloy:v1.18.0` | 메트릭·로그 수집 후 push. healthcheck: `:12345/-/ready` |
| `argos-alloy-files` | `grafana/alloy:v1.18.0` | 애플리케이션 로그 파일 수집 (`LOG_DIRS` 지정 시에만). 포트 없음 |
| `argos-docker-proxy` | `haproxy:3.2.26-alpine` (Docker 공식 이미지) | Docker API 읽기 전용 프록시. 포트 없음, 내부망 전용 |

`latest`를 쓰지 않고 고정합니다 — 노드마다 다른 버전이 깔리는 걸 막기 위함입니다.
Alloy 버전이 다르면 수집 항목·라벨이 미묘하게 어긋날 수 있습니다.

### Docker 소켓 — Alloy 는 조회만 할 수 있다

Alloy 는 cAdvisor(컨테이너 메트릭)와 컨테이너 로그 수집에 Docker API 가 필요합니다.
예전에는 `docker.sock` 을 직접 마운트했는데, `:ro` 를 붙여도 API 는 전부 쓸 수 있어서
Alloy 가 뚫리면 `docker run -v /:/host --privileged …` 한 줄로 곧 호스트 root 였습니다.

지금은 `argos-docker-proxy` 가 소켓을 대신 잡고, Alloy 에는 실제로 쓰는 조회 경로 7개만 열어 줍니다
(`docker-proxy.cfg`). dind 실측(2026-11-09):

| Alloy 네트워크에서 보낸 요청 | 결과 |
|---|---|
| 컨테이너 목록·정보·로그, `info`, `version` | 200 (수집 정상: 로그 3/3, cAdvisor 메트릭 정상) |
| 컨테이너 생성·`exec`·`kill`·삭제 | **403** |
| 컨테이너 파일 꺼내기(`archive`·`export`), 이미지 목록 | **403** |

- 프록시는 외부로 나가는 경로가 없는 내부 네트워크(`dockerapi`)에 Alloy 하고만 붙어 있습니다.
  파일 로그 컨테이너(`argos-alloy-files`)는 이 망에 없어 Docker API 에 닿지 않습니다.
- 프록시는 root 로 돌지만(소켓이 root 소유) 권한(capability)을 전부 빼고 읽기 전용 파일시스템으로 돕니다.
- Alloy 를 올린 뒤 컨테이너 메트릭·로그가 비면 `sudo docker logs argos-docker-proxy` 로 막힌 요청을 봅니다
  (거부된 요청만 기록됩니다). 새 경로가 필요하면 `docker-proxy.cfg` 허용 목록에 추가합니다.

호스트 `/`(`/:/rootfs:ro`)는 여전히 Alloy 에 읽기 전용으로 붙어 있습니다. cAdvisor 와 디스크 사용량 수집에
필요해서 뺄 수 없습니다. 그래서 Alloy 를 외부에서 건드릴 수 없게 하는 것(12345 포트를 루프백에만)과
버전을 올려 두는 것이 대응입니다.

업그레이드는 `compose/docker-compose.yml`을 고쳐 커밋으로 남깁니다. `compose/docker-compose.files.yml` 의
Alloy 버전도 같이 올려야 합니다 — 둘이 다르면 `init` 이 파일 로그 설치를 중단합니다.
`docker compose pull`만으로는 버전이 올라가지 않습니다.

### 자동 재시작 (`argos-autoheal` 타이머)

`restart: unless-stopped`는 프로세스가 죽었을 때만 살립니다. Alloy가 살아는 있지만
수집이 멈춘 상태(healthcheck 실패)는 Docker 가 재시작하지 않으므로 따로 둡니다.

예전에는 `willfarrell/autoheal` 컨테이너가 했는데, `docker.sock` 을 통째로 받아야 했습니다(사실상 호스트 root).
개인이 관리하는 이미지이고 버전 태그가 2021년에 멈춰 있었습니다. 하는 일이 "unhealthy 컨테이너 재시작" 몇 줄이라
지금은 호스트의 systemd 타이머가 30초마다 `host/argos-autoheal` 을 실행합니다.

- 대상: 라벨 `autoheal=true` 컨테이너 (`argos-alloy`, `argos-alloy-files`)
- 기록: `journalctl -u argos-autoheal` — journald 라 중앙 Loki 에도 갑니다
- 예전 버전에서 올리면 `argos-autoheal` 컨테이너는 `--remove-orphans` 로 내려갑니다
- systemd 가 없는 호스트에서는 경고만 하고 넘어갑니다(자동 재시작 없음)

## 관리

```bash
cd /opt/argos-agent

sudo docker compose ps            # 상태 확인
sudo docker compose logs -f       # 로그
sudo docker compose restart       # 재시작
sudo docker compose down          # 중지

curl -s localhost:12345/-/ready     # Alloy 헬스 (이 노드 안에서만 열림)
systemctl list-timers argos-autoheal.timer   # 자동 재시작 타이머
```

`init` 은 일반 계정(`ec2-user`·`ubuntu`)을 docker 그룹에 넣지 않습니다. docker 그룹은 sudo 없이 호스트 root 와 같아서,
모니터링 에이전트 설치가 사용자 권한을 바꾸지 않게 했습니다. 관리 명령은 `sudo docker …` 로 실행합니다.
(예전 버전으로 이미 추가된 계정은 그대로 남습니다 — 빼려면 `sudo gpasswd -d ec2-user docker`)

12345 포트는 `127.0.0.1` 에만 열립니다. 인증 없는 UI·디버그(`/debug/pprof`) 포트라 다른 서버에서 접속할 이유가 없습니다.
수집 데이터는 이 포트가 아니라 Alloy 가 중앙으로 push 합니다.

## 옵션

| 플래그 | 기본 | 설명 |
|--------|------|------|
| `--up` | — | 마지막에 `docker compose up -d --force-recreate --remove-orphans` 까지 수행 |
| `--no-up` | ✔ | 기동하지 않음 (기본값, 명시용) |

| 환경변수 | 기본 | 설명 |
|---------|------|------|
| `BASE_DIR` | `/opt/argos-agent` | 설치 경로 |
| `COMPOSE_UP` | `0` | `1`이면 `--up`과 동일 |
| `INSTALL_GIT` | `1` | git 설치 |
| `INSTALL_DOCKER` | `1` | Docker/Compose 설치 |
| `COMPOSE_VERSION` | `v2.32.4` | Compose 플러그인 버전 (패키지 설치가 안 될 때만 GitHub 에서 받음. 기본 버전은 init 에 고정한 해시로, 다른 버전은 릴리스의 `.sha256` 으로 확인 후 설치) |
| `INSTALL_CMD_AUDIT` | `1` | 명령 실행 감사 설치 |
| `INSTALL_AUTOHEAL` | `1` | unhealthy 컨테이너 자동 재시작 타이머 설치 |
| `INSTANCE_ID` | EC2 instance-id | 없으면 hostname. 제어 문자는 지우고 `" ' \ $ `` ` `` 는 `_` 로 바꿈 |
| `NODE_NAME` | EC2 Name 태그 | 없으면 `INSTANCE_ID`. 처리는 위와 같음 (Name 태그는 콘솔에서 누구나 바꿀 수 있어 그대로 믿지 않음) |
| `KEEP_ENV` | `0` | `1`이면 기존 `.env` 덮어쓰지 않음 |
| `COMPOSE_SRC` | `<스크립트>/compose` | 설정 원본 경로 |
| `LOG_KEEP_REGEX` | (없음) | 컨테이너 로그 필터 |
| `LOG_DIRS` | (없음 = 수집 안 함) | 파일 로그 수집 디렉터리, 콤마로 여러 개 (`--log-dir=<경로>` 와 같음) |
| `LOG_FILE_EXT` | `log,out,txt` | 파일 로그 확장자 |
| `LOG_RATE` | `100` | 로그 전송량 상한: 컨테이너·파일마다 초당 줄 수 (journald 는 2배) |
| `LOG_BURST` | `1000` | 로그 전송량 상한: 순간 허용 줄 수 (journald 는 2배) |

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
