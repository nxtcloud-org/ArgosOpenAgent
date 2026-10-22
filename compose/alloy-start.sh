#!/bin/bash
# Alloy 기동 래퍼 — /log 파일 수집(config.alloy "로그 3")의 첫 읽기 위치를 정한 뒤 alloy 를 실행한다.
#
# 이 파일이 유일한 정답(single source of truth)이다. init 이 그대로 복사한다.
#
# 왜 필요한가:
#   원하는 동작은 "설치 시점에 이미 있던 파일은 끝부터(쌓인 수 GB 를 보내지 않음),
#   그 뒤에 생긴 파일은 처음부터(날짜별 새 파일의 첫 줄을 잃지 않음)" 이다.
#   Alloy 의 tail_from_end 는 둘을 구분하지 못한다(v1.18.0 실측):
#     - true  : 실행 중에 새로 생긴 파일도 끝부터 → 발견 전(sync_period)에 쓰인 첫 줄들이 유실
#     - false : 설치 순간 기존 파일 전체를 처음부터 → 홈페이지 5 GB 등이 한꺼번에 중앙으로
#   그리고 true 여도 한 줄도 읽지 않은(쓰기가 없는) 파일은 위치가 저장되지 않아,
#   "처음엔 true 로 띄웠다가 false 로 바꾸기"도 조용한 파일에서 실패한다.
#   그래서 위치 파일이 없을 때(설치 직후·alloy-data 볼륨 초기화) 기존 파일의 현재 크기를
#   Alloy 위치 파일 형식으로 직접 써 두고, alloy 는 항상 tail_from_end=false 로 돈다.
#
# 위치 파일 형식은 Alloy 내부 형식이다(키 = path + 라벨 문자열, 라벨은 이름순·", " 구분).
# 라벨이 config.alloy 의 discovery.relabel "logvol" 결과와 한 글자라도 다르면 Alloy 가 다른
# 대상으로 보고 처음부터 읽는다. Alloy 를 올리거나 logvol 라벨을 바꾸면 이 파일도 같이 확인할 것.
set -u
shopt -s globstar dotglob nullglob

POS=/var/lib/alloy/data/loki.source.file.logvol/positions.yml
LOG_ROOT=/rootfs/log

if [ ! -f "$POS" ]; then
  mkdir -p "${POS%/*}"
  body=""
  n=0
  for f in "$LOG_ROOT"/**/*; do
    # config.alloy local.file_match "logvol" 의 패턴(**/*.{log,out,txt})과 같아야 한다
    case "$f" in *.log|*.out|*.txt) ;; *) continue ;; esac
    [ -f "$f" ] || continue
    rel=${f#"$LOG_ROOT"/}
    if [[ $rel == */* ]]; then app=${rel%%/*}; else app=log; fi
    # 따옴표·역슬래시가 든 이름은 YAML/라벨 이스케이프가 꼬일 수 있어 건너뛴다(처음부터 읽힌다)
    case "$f$app" in *[\'\"\\]*) continue ;; esac
    size=$(stat -c %s "$f" 2>/dev/null) || continue
    body+="  ? path: \"$f\""$'\n'
    body+="    labels: '{app=\"$app\", instance=\"${INSTANCE_ID}\", job=\"file\", node=\"${NODE_NAME}\"}'"$'\n'
    body+="  : \"$size\""$'\n'
    n=$((n + 1))
  done
  if [ "$n" -gt 0 ]; then
    printf 'positions:\n%s' "$body" > "$POS.tmp"
  else
    printf 'positions: {}\n' > "$POS.tmp"
  fi
  mv "$POS.tmp" "$POS"
  echo "[alloy-start] /log 기존 파일 ${n}개의 현재 위치를 기록 — 이후 추가분만 전송"
fi

exec /bin/alloy "$@"
