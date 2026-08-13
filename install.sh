#!/usr/bin/env bash
set -euo pipefail

# ═══════════════════════════════════════════════════════════════════
# ArgosOpen Agent — 모니터링 에이전트 설치 스크립트
#
# 사용법:
#   sudo ./install.sh <중앙노드_사설IP>
#
# 예시:
#   sudo ./install.sh 10.32.20.100
#
# 수행 내용:
#   1. Docker / Docker Compose 설치 (미설치 시)
#   2. Alloy config + docker-compose.yml 생성 (/opt/argos-agent/)
#   3. 명령 실행 감사(cmdaudit) 설치
#   4. docker compose up -d (자동 기동)
#
# 생성 파일:
#   /opt/argos-agent/
#   ├── docker-compose.yml   # Alloy 컨테이너 정의
#   ├── config.alloy          # Alloy 수집 설정
#   └── .env                  # 런타임 변수 (INSTANCE_ID, NODE_NAME 등)
# ═══════════════════════════════════════════════════════════════════

CENTRAL_HOST="${1:-}"
if [ -z "$CENTRAL_HOST" ]; then
  echo "사용법: sudo $0 <중앙노드_사설IP>"
  echo "  예: sudo $0 10.32.20.100"
  exit 1
fi

# ─── 설정 (필요 시 수정) ───
BASE_DIR="${ARGOS_BASE_DIR:-/opt/argos-agent}"
INSTALL_DOCKER="${INSTALL_DOCKER:-1}"
INSTALL_CMD_AUDIT="${INSTALL_CMD_AUDIT:-1}"
COMPOSE_UP="${COMPOSE_UP:-1}"

# 컨테이너 로그 필터: 이 정규식에 매칭되는 줄만 중앙으로 보낸다.
# 비워두면 모든 컨테이너 로그를 보낸다.
LOG_KEEP_REGEX="${LOG_KEEP_REGEX:-}"
LOG_MULTILINE_FIRSTLINE="${LOG_MULTILINE_FIRSTLINE:-^[0-9]{4}-[0-9]{2}-[0-9]{2}|^\\\\[|^\\\\{|^[A-Z][a-z]{2} [0-9]}"

log() { echo "[argos] $*"; }
err() { echo "[argos] ERROR: $*" >&2; }

# ─── 노드 식별자 자동 감지 ───
detect_identity() {
  local token url

  # IMDSv2 토큰
  token="$(curl -sf -X PUT -H 'X-aws-ec2-metadata-token-ttl-seconds: 10' \
    http://169.254.169.254/latest/api/token 2>/dev/null || true)"
  if [ -n "$token" ]; then
    url="http://169.254.169.254/latest/meta-data"
    INSTANCE_ID="$(curl -sf -H "X-aws-ec2-metadata-token: $token" "$url/instance-id" || true)"
    NODE_NAME="$(curl -sf -H "X-aws-ec2-metadata-token: $token" "$url/tags/instance/Name" || true)"
  fi

  # fallback
  INSTANCE_ID="${INSTANCE_ID:-$(hostname -s)}"
  NODE_NAME="${NODE_NAME:-$(hostname -s)}"

  log "노드 식별자 = $INSTANCE_ID (node=$NODE_NAME)"
}

# ─── Docker 설치 ───
install_docker() {
  if command -v docker >/dev/null 2>&1; then
    log "Docker 이미 설치됨: $(docker --version)"
    return 0
  fi
  log "Docker 설치 중..."
  if   command -v dnf     >/dev/null 2>&1; then dnf install -y docker
  elif command -v yum     >/dev/null 2>&1; then yum install -y docker
  elif command -v apt-get >/dev/null 2>&1; then apt-get update && apt-get install -y docker.io
  else err "패키지 매니저를 찾을 수 없습니다"; exit 1
  fi
  systemctl enable --now docker 2>/dev/null || true
  for u in ec2-user ubuntu; do id "$u" >/dev/null 2>&1 && usermod -aG docker "$u" || true; done
}

install_compose() {
  if docker compose version >/dev/null 2>&1; then
    log "Docker Compose 이미 설치됨: $(docker compose version | head -1)"
    return 0
  fi
  log "Docker Compose 설치 중..."
  dnf install -y docker-compose-plugin 2>/dev/null \
    || apt-get install -y docker-compose-plugin 2>/dev/null || true
  if docker compose version >/dev/null 2>&1; then return; fi

  local COMPOSE_VERSION="v2.32.4"
  local arch; arch="$(uname -m)"
  local dir="/usr/local/lib/docker/cli-plugins"
  mkdir -p "$dir"
  curl -SL "https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}/docker-compose-linux-${arch}" \
    -o "$dir/docker-compose"
  chmod +x "$dir/docker-compose"
}

# ─── Alloy 설정 생성 ───
write_alloy_config() {
  local d="$1"
  cat > "$d/config.alloy" <<'ALLOY'
logging {
  level  = "info"
  format = "logfmt"
}

// ── 메트릭 1) 호스트 OS (node_exporter 내장) ──
prometheus.exporter.unix "host" {
  procfs_path = "/host/proc"
  sysfs_path  = "/host/sys"
  rootfs_path = "/rootfs"
  filesystem {
    mount_points_exclude = "^/(dev|proc|sys|run|var/lib/docker/.+|host/.+|boot/efi)($|/)"
    fs_types_exclude     = "^(autofs|binfmt_misc|cgroup|cgroup2|configfs|debugfs|devpts|devtmpfs|efivarfs|fusectl|hugetlbfs|iso9660|mqueue|nfs|nfs4|nfsd|nsfs|overlay|proc|procfs|pstore|ramfs|rpc_pipefs|securityfs|selinuxfs|squashfs|sunrpc|sysfs|tracefs|tmpfs|vfat)$"
    mount_timeout        = "5s"
  }
}
discovery.relabel "host" {
  targets = prometheus.exporter.unix.host.targets
  rule { target_label = "job";      replacement = "node" }
  rule { target_label = "instance"; replacement = sys.env("INSTANCE_ID") }
  rule { target_label = "node";     replacement = sys.env("NODE_NAME") }
}
prometheus.scrape "host" {
  targets         = discovery.relabel.host.output
  forward_to      = [prometheus.remote_write.mimir.receiver]
  scrape_interval = "15s"
}

// ── 메트릭 2) 컨테이너 (cAdvisor 내장) ──
prometheus.exporter.cadvisor "containers" {
  docker_host      = "unix:///var/run/docker.sock"
  storage_duration = "5m"
}
discovery.relabel "containers" {
  targets = prometheus.exporter.cadvisor.containers.targets
  rule { target_label = "instance"; replacement = sys.env("INSTANCE_ID") }
  rule { target_label = "node";     replacement = sys.env("NODE_NAME") }
}
prometheus.scrape "containers" {
  targets         = discovery.relabel.containers.output
  forward_to      = [prometheus.remote_write.mimir.receiver]
  scrape_interval = "15s"
  job_name        = "cadvisor"
}

// ── 메트릭 push ──
prometheus.remote_write "mimir" {
  endpoint { url = sys.env("MIMIR_ENDPOINT") }
  external_labels = { cluster = "poc" }
}

// ── 로그 1) 컨테이너 (docker.sock tail) ──
discovery.docker "logs" { host = "unix:///var/run/docker.sock" }
discovery.relabel "logs" {
  targets = discovery.docker.logs.targets
  rule {
    source_labels = ["__meta_docker_container_name"]
    regex         = "/(.*)"
    target_label  = "container"
  }
  rule { target_label = "instance"; replacement = sys.env("INSTANCE_ID") }
  rule { target_label = "node";     replacement = sys.env("NODE_NAME") }
}
loki.source.docker "logs" {
  host       = "unix:///var/run/docker.sock"
  targets    = discovery.relabel.logs.output
  labels     = { job = "docker" }
  forward_to = [__DOCKER_SINK__]
}
__FILTER_BLOCK__
// ── 로그 2) systemd journald ──
loki.source.journal "system" {
  forward_to = [loki.write.loki.receiver]
  labels     = { job = "systemd-journal", instance = sys.env("INSTANCE_ID"), node = sys.env("NODE_NAME") }
}

// ── 로그 push ──
loki.write "loki" {
  endpoint { url = sys.env("LOKI_ENDPOINT") }
  external_labels = { cluster = "poc" }
}
ALLOY

  # ── 컨테이너 로그 필터 주입 ──
  local sink tmp="$d/config.alloy.tmp" blockfile="$d/.filter-block.tmp"
  : > "$blockfile"
  if [ -n "$LOG_KEEP_REGEX" ]; then
    sink="loki.process.container_filter.receiver"
    cat > "$blockfile" <<FILTER

// ── 컨테이너 로그 필터 ──
loki.process "container_filter" {
  forward_to = [loki.write.loki.receiver]

  stage.multiline {
    firstline     = "${LOG_MULTILINE_FIRSTLINE}"
    max_wait_time = "3s"
  }

  stage.match {
    selector            = "{container!=\"\"} !~ \"${LOG_KEEP_REGEX}\""
    action              = "drop"
    drop_counter_reason = "below_keep_regex"
  }
}
FILTER
    log "컨테이너 로그 필터 활성화: '${LOG_KEEP_REGEX}'"
  else
    sink="loki.write.loki.receiver"
  fi

  awk -v sink="$sink" -v bf="$blockfile" '
    { gsub(/__DOCKER_SINK__/, sink) }
    $0 == "__FILTER_BLOCK__" {
      while ((getline line < bf) > 0) print line
      close(bf); next
    }
    { print }
  ' "$d/config.alloy" > "$tmp" && mv "$tmp" "$d/config.alloy"
  rm -f "$blockfile"

  if grep -q '__[A-Z_]*__' "$d/config.alloy"; then
    err "config.alloy 에 치환되지 않은 placeholder 가 남았습니다"
    return 1
  fi
}

# ─── docker-compose.yml 생성 ───
write_compose() {
  local d="$1"
  cat > "$d/docker-compose.yml" <<'YAML'
# ArgosOpen Agent — Alloy 모니터링 에이전트
services:
  alloy:
    image: grafana/alloy:latest
    container_name: argos-alloy
    restart: unless-stopped
    cgroup: host
    devices:
      - /dev/kmsg:/dev/kmsg
    command:
      - run
      - --server.http.listen-addr=0.0.0.0:12345
      - --storage.path=/var/lib/alloy/data
      - /etc/alloy/config.alloy
    environment:
      MIMIR_ENDPOINT: ${MIMIR_ENDPOINT}
      LOKI_ENDPOINT: ${LOKI_ENDPOINT}
      INSTANCE_ID: ${INSTANCE_ID}
      NODE_NAME: ${NODE_NAME}
    ports: ["12345:12345"]
    volumes:
      - ./config.alloy:/etc/alloy/config.alloy:ro
      - alloy-data:/var/lib/alloy/data
      - /proc:/host/proc:ro
      - /sys:/host/sys:ro
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - /run/udev:/run/udev:ro
      - /:/rootfs:ro
      - /sys/fs/cgroup:/sys/fs/cgroup:ro
      - /var/lib/docker/:/var/lib/docker:ro
      - /dev/disk/:/dev/disk:ro
      - /var/log/journal:/var/log/journal:ro
      - /run/log/journal:/run/log/journal:ro
      - /etc/machine-id:/etc/machine-id:ro
    healthcheck:
      test: ["CMD", "wget", "-q", "--spider", "http://localhost:12345/-/ready"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 15s
    labels:
      - "autoheal=true"
    networks: [argos]

  # 헬스체크 실패 시 자동 재시작
  autoheal:
    image: willfarrell/autoheal:latest
    container_name: argos-autoheal
    restart: unless-stopped
    environment:
      AUTOHEAL_CONTAINER_LABEL: "autoheal"
      AUTOHEAL_INTERVAL: 30
      AUTOHEAL_START_PERIOD: 60
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
    networks: [argos]

volumes:
  alloy-data:

networks:
  argos:
YAML
}

# ─── 명령 실행 감사(cmdaudit) ───
install_cmd_audit() {
  if [ "$INSTALL_CMD_AUDIT" != "1" ]; then
    log "INSTALL_CMD_AUDIT=0 → 명령 실행 감사 설치 건너뜀"
    return 0
  fi

  local f="/etc/profile.d/zz-cmd-audit.sh"
  cat > "${f}.tmp" <<'CMDAUDIT'
[ -n "${BASH_VERSION:-}" ] || return 0
case $- in *i*) ;; *) return 0 ;; esac
command -v logger >/dev/null 2>&1 || return 0

if [ -z "${__CMD_AUDIT_LOGIN:-}" ]; then
  __CMD_AUDIT_LOGIN="$(logname 2>/dev/null)" || __CMD_AUDIT_LOGIN=""
  [ -n "$__CMD_AUDIT_LOGIN" ] || __CMD_AUDIT_LOGIN="${SUDO_USER:-$(id -un 2>/dev/null)}"
  export __CMD_AUDIT_LOGIN
fi
__CMD_AUDIT_TTY="$(tty 2>/dev/null)" || __CMD_AUDIT_TTY="-"

__cmd_audit() {
  local e n c
  e="$(history 1 2>/dev/null)" || return 0
  e=${e#"${e%%[![:space:]]*}"}
  n=${e%%[[:space:]]*}
  c=${e#*[[:space:]]}
  c=${c#"${c%%[![:space:]]*}"}
  [ -n "$c" ] || return 0
  [ "$n" = "${__CMD_AUDIT_LAST:-}" ] && return 0
  __CMD_AUDIT_LAST="$n"
  logger -t cmdaudit -p local6.notice -- \
    "CMDAUDIT login=${__CMD_AUDIT_LOGIN} user=$(id -un 2>/dev/null) tty=${__CMD_AUDIT_TTY} pwd=${PWD} cmd=${c}" \
    2>/dev/null
  return 0
}

case ";${PROMPT_COMMAND:-};" in
  *";__cmd_audit;"*) ;;
  *) PROMPT_COMMAND="__cmd_audit${PROMPT_COMMAND:+;$PROMPT_COMMAND}" ;;
esac
CMDAUDIT

  if ! bash -n "${f}.tmp" 2>/dev/null; then
    err "명령 감사 스크립트 문법 오류 → 설치 중단"
    rm -f "${f}.tmp"
    return 1
  fi

  mv "${f}.tmp" "$f"
  chmod 644 "$f"
  log "명령 실행 감사 설치: $f"
  log "  이미 열려 있는 셸에는 적용되지 않습니다 — 다시 로그인해야 기록이 시작됩니다."
}

# ═══════════════════════════ 메인 ═══════════════════════════

detect_identity

if [ "$INSTALL_DOCKER" = "1" ]; then
  install_docker
  install_compose
fi

log "에이전트 설정 생성: $BASE_DIR (중앙=$CENTRAL_HOST)"
mkdir -p "$BASE_DIR"

# .env
cat > "$BASE_DIR/.env" <<ENV
MIMIR_ENDPOINT=http://${CENTRAL_HOST}:9009/api/v1/push
LOKI_ENDPOINT=http://${CENTRAL_HOST}:3100/loki/api/v1/push
INSTANCE_ID=${INSTANCE_ID}
NODE_NAME=${NODE_NAME}
ENV

write_compose "$BASE_DIR"
write_alloy_config "$BASE_DIR"

install_cmd_audit || err "명령 감사 설치 실패 — 에이전트 기동은 계속합니다."

if [ "$COMPOSE_UP" = "1" ]; then
  log "기동: docker compose up -d ($BASE_DIR)"
  ( cd "$BASE_DIR" && docker compose up -d )
  log "기동 완료."
else
  log "COMPOSE_UP=0 → 기동 건너뜀. 수동 기동: cd $BASE_DIR && docker compose up -d"
fi

cat <<TIP

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 ArgosOpen Agent 설치 완료
   노드: ${NODE_NAME} (${INSTANCE_ID})
   중앙: ${CENTRAL_HOST} (Mimir :9009, Loki :3100)
   설치 경로: ${BASE_DIR}

 관리 명령:
   cd ${BASE_DIR}
   docker compose ps          # 상태 확인
   docker compose logs -f     # 로그 확인
   docker compose restart     # 재시작
   docker compose down        # 중지
   docker compose pull && docker compose up -d   # 업데이트

 [보안그룹] 이 노드 → 중앙 노드 아웃바운드:
   TCP 9009 (메트릭), TCP 3100 (로그)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
TIP
