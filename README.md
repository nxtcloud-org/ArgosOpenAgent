# ArgosOpen Agent

EC2 인스턴스에 모니터링 에이전트(Grafana Alloy)를 설치하는 스크립트.

호스트 OS 메트릭(CPU/MEM/Disk/Network) + 컨테이너 메트릭 + 시스템/컨테이너 로그 + 명령 실행 감사를 중앙 모니터링 노드(Mimir + Loki)로 push합니다.

## 빠른 시작

### 방법 1: 원샷 설치 (`init`)

```bash
sudo ./init agent <중앙노드_사설IP>

# 예시
sudo ./init agent 10.32.20.100
```

Docker/Docker Compose 설치 → Alloy 설정 생성 → cmdaudit 설치 → `docker compose up -d` 를 한 번에 수행합니다.

설치 후 수동 기동만 하고 싶으면:

```bash
COMPOSE_UP=0 sudo ./init agent 10.32.20.100

# 이후 필요할 때
cd /opt/argos-agent && docker compose up -d
```

### 방법 2: Docker Compose 수동 배포

Docker가 이미 설치된 환경에서 `init` 없이 직접 배포:

```bash
sudo mkdir -p /opt/argos-agent
sudo cp compose/docker-compose.yml compose/config.alloy /opt/argos-agent/
sudo cp compose/.env.example /opt/argos-agent/.env
sudo vi /opt/argos-agent/.env   # 값 채우기

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

## 프로젝트 구조

```
├── init                        # 원샷 부트스트랩: ./init agent <IP>
├── compose/
│   ├── docker-compose.yml      # Alloy + autoheal 컨테이너 정의 (참조/수동 배포용)
│   ├── config.alloy            # Alloy 수집 설정 기본값 (필터 없음)
│   └── .env.example            # 환경변수 템플릿
└── README.md
```

`init`이 생성하는 파일 (`/opt/argos-agent/`):

```
├── docker-compose.yml          # Alloy + autoheal
├── config.alloy                # Alloy 수집 설정 (로그 필터 적용됨)
└── .env                        # MIMIR/LOKI 엔드포인트, 노드 식별자
```

## 관리

```bash
cd /opt/argos-agent

docker compose ps            # 상태 확인
docker compose logs -f       # 로그
docker compose restart       # 재시작
docker compose down          # 중지
docker compose pull && docker compose up -d  # 업데이트
```

## 설정 옵션

환경변수로 동작을 제어할 수 있습니다:

```bash
# Docker 설치 건너뛰기 (이미 설치됨)
INSTALL_DOCKER=0 sudo ./init agent 10.32.20.100

# 설치만 하고 기동은 안 함
COMPOSE_UP=0 sudo ./init agent 10.32.20.100

# 명령 감사 설치 건너뛰기
INSTALL_CMD_AUDIT=0 sudo ./init agent 10.32.20.100

# 컨테이너 로그 필터 (매칭되는 줄만 전송)
LOG_KEEP_REGEX="(?i)(error|warn|fatal)" sudo ./init agent 10.32.20.100

# 설치 경로 변경
BASE_DIR=/home/ec2-user/agent sudo ./init agent 10.32.20.100
```

## 보안그룹

이 노드에서 중앙 노드로 아웃바운드 허용 필요:
- TCP 9009 (Mimir — 메트릭)
- TCP 3100 (Loki — 로그)
