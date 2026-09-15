#!/usr/bin/env bash
#
# deliverable-review 스킬 규칙에 따라 프로젝트 루트의 docs/YYMMDD/ 아래에 리뷰 보고서 파일을 템플릿으로 만든다.
#
# 보고서 경로와 차수 결정, 템플릿 적용을 이 스크립트가 일괄 처리하므로
# 어떤 에이전트가 리뷰하더라도 같은 위치에 같은 구조로 보고서가 만들어진다.
# 에이전트는 만들어진 보고서의 안내 주석에 따라 내용을 작성한 뒤 check-report.sh로 검증한다.
#
# 사용법:
#   create-report.sh <doc|code> <영문 대상명...> --title <리뷰 대상 제목> --target <리뷰 대상> [옵션]
#
# 예시:
#   create-report.sh code kakao-social-login --title "카카오 소셜 로그인 구현" \
#     --target "feat/128-add-kakao-social-login (기준: origin/develop)"
#
# 결과 (표준 출력, key=value 형식):
#   RESULT=created | dry-run
#   REPORT_PATH=<보고서 절대 경로>
#   REPORT_RELATIVE_PATH=<프로젝트 루트 기준 보고서 경로>
#   REPORT_DATE=<YYMMDD>
#   REVIEW_ROUND=<같은 날 같은 대상의 리뷰 차수>
#
# 종료 코드:
#   0  성공
#   1  환경 오류 (템플릿 없음, 프로젝트 루트 확인 실패, 파일 생성 실패)
#   2  인자 오류
#   3  영문 대상명 길이 초과
#
# 요구 사항: bash 3.2 이상, awk

set -euo pipefail

readonly MAX_NAME_LENGTH=50

log()  { printf '[deliverable-review] %s\n' "$*" >&2; }
warn() { printf '[deliverable-review] 경고: %s\n' "$*" >&2; }
die() {
  local code="$1"
  shift
  printf '[deliverable-review] 오류: %s\n' "$*" >&2
  exit "$code"
}

usage() {
  cat <<'EOF'
사용법: create-report.sh <doc|code> <영문 대상명...> --title <리뷰 대상 제목> --target <리뷰 대상> [옵션]

옵션:
  --title <제목>         리뷰 대상 제목 (필수, 보고서 제목은 '<제목> 리뷰')
  --target <리뷰 대상>   메타데이터 표에 적을 문서 경로나 브랜치 (필수)
  --author <이름>        리뷰어 (기본: Git 설정의 user.name)
  --root <디렉터리>      프로젝트 루트 (기본: Git 저장소 최상위 디렉터리, Git 저장소가 아니면 현재 디렉터리)
  --dry-run              보고서 경로만 확인하고 파일은 만들지 않는다
  -h, --help             도움말을 출력한다

보고서는 <프로젝트 루트>/docs/<YYMMDD>/<영문 대상명>-<doc|code>-review.md 경로에 만들고,
같은 날 같은 대상의 보고서가 이미 있으면 -review-2.md처럼 차수를 붙인다.
EOF
}

# ---------------------------------------------------------------------------
# 인자 해석
# ---------------------------------------------------------------------------

review_type=""
name=""
title=""
target=""
author=""
root=""
dry_run=false

need_value() {
  [ "$2" -ge 2 ] || die 2 "옵션에 값이 필요합니다: $1"
}

add_positional() {
  if [ -z "$review_type" ]; then
    review_type="$1"
  else
    name="${name:+$name }$1"
  fi
}

while [ $# -gt 0 ]; do
  case "$1" in
    --title)   need_value "$1" $#; title="$2"; shift 2 ;;
    --target)  need_value "$1" $#; target="$2"; shift 2 ;;
    --author)  need_value "$1" $#; author="$2"; shift 2 ;;
    --root)    need_value "$1" $#; root="$2"; shift 2 ;;
    --dry-run) dry_run=true; shift ;;
    -h|--help) usage; exit 0 ;;
    --)        shift; while [ $# -gt 0 ]; do add_positional "$1"; shift; done ;;
    -*)        die 2 "알 수 없는 옵션입니다: $1" ;;
    *)         add_positional "$1"; shift ;;
  esac
done

# ---------------------------------------------------------------------------
# 입력 검증
# ---------------------------------------------------------------------------

case "$review_type" in
  doc)  type_label="설계 문서" ;;
  code) type_label="코드 변경" ;;
  "")   usage >&2; die 2 "리뷰 대상 유형(doc 또는 code)을 입력해야 합니다." ;;
  *)    die 2 "리뷰 대상 유형은 doc 또는 code여야 합니다: '$review_type'" ;;
esac

[ -n "$name" ] || die 2 "영문 대상명을 입력해야 합니다."
name="$(printf '%s' "$name" | tr '\r\n\t' '   ')"
if LC_ALL=C grep -q '[^[:print:]]' <<< "$name"; then
  die 2 "영문 대상명에 영문이 아닌 문자가 있습니다. 리뷰 대상을 영문으로 번역해서 전달하세요: '$name'"
fi

slug="$(printf '%s' "$name" \
  | tr '[:upper:]' '[:lower:]' \
  | sed -E 's/[[:space:]]+$//; s/\.md$//' \
  | tr -d "'\"\`" \
  | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')"
[ -n "$slug" ] || die 2 "영문 대상명에 영문자나 숫자가 없습니다: '$name'"
if [ "${#slug}" -gt "$MAX_NAME_LENGTH" ]; then
  die 3 "영문 대상명이 ${#slug}자로 ${MAX_NAME_LENGTH}자를 넘습니다. 핵심 키워드만 남기고 다시 실행하세요: '$slug'"
fi

single_line_value() {
  printf '%s' "$1" | LC_ALL=C sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//'
}

title="$(single_line_value "$title")"
title="${title#\# }"
[ -n "$title" ] || die 2 "리뷰 대상 제목을 --title 옵션으로 입력해야 합니다."
target="$(single_line_value "$target")"
[ -n "$target" ] || die 2 "리뷰 대상을 --target 옵션으로 입력해야 합니다."
for value in "$title" "$target"; do
  if [[ "$value" == *$'\n'* || "$value" == *$'\r'* ]]; then
    die 2 "제목과 리뷰 대상은 한 줄로 작성해야 합니다."
  fi
done

author="$(printf '%s' "$author" | tr '\r\n\t' '   ' | LC_ALL=C sed -E 's/^ +//; s/ +$//')"

# ---------------------------------------------------------------------------
# 템플릿, 프로젝트 루트, 보고서 경로 결정
# ---------------------------------------------------------------------------

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
template="$script_dir/../templates/review-report.md"
[ -f "$template" ] || die 1 "리뷰 보고서 템플릿을 찾을 수 없습니다: $template"

if [ -n "$root" ]; then
  [ -d "$root" ] || die 1 "프로젝트 루트 디렉터리를 찾을 수 없습니다: $root"
  root="$(cd "$root" && pwd)"
elif git_root="$(git rev-parse --show-toplevel 2>/dev/null)"; then
  root="$git_root"
else
  root="$(pwd)"
  warn "Git 저장소가 아니어서 현재 디렉터리를 프로젝트 루트로 사용합니다: $root"
fi

if [ -z "$author" ]; then
  author="$(git -C "$root" config user.name 2>/dev/null || true)"
  [ -n "$author" ] || author="-"
fi

created_date="$(date +%Y-%m-%d)"
report_date="${created_date:2:2}${created_date:5:2}${created_date:8:2}"

docs_dir="$root/docs"
date_dir="$docs_dir/$report_date"
if [ -e "$docs_dir" ] && [ ! -d "$docs_dir" ]; then
  die 1 "docs가 디렉터리가 아닌 파일로 존재합니다: $docs_dir"
fi

# 같은 날 같은 대상을 다시 리뷰하면 기존 보고서를 덮어쓰지 않고 차수를 올린다.
file_base="$slug-$review_type-review"
round=1
file_name="$file_base.md"
while [ -e "$date_dir/$file_name" ] || [ -L "$date_dir/$file_name" ]; do
  round=$((round + 1))
  file_name="$file_base-$round.md"
done

report_path="$date_dir/$file_name"
relative_path="docs/$report_date/$file_name"

print_result() {
  printf 'RESULT=%s\n' "$1"
  printf 'REPORT_PATH=%s\n' "$report_path"
  printf 'REPORT_RELATIVE_PATH=%s\n' "$relative_path"
  printf 'REPORT_DATE=%s\n' "$report_date"
  printf 'REVIEW_ROUND=%s\n' "$round"
}

if [ "$round" -gt 1 ]; then
  log "같은 날 같은 대상의 리뷰 보고서가 있어 ${round}차 보고서를 만듭니다."
fi

if [ "$dry_run" = true ]; then
  log "--dry-run 옵션에 따라 보고서 파일을 만들지 않습니다."
  print_result dry-run
  exit 0
fi

# ---------------------------------------------------------------------------
# 템플릿으로 보고서 생성
# ---------------------------------------------------------------------------

# 제목이나 대상에 특수 문자가 있어도 그대로 들어가도록, 정규식 치환 대신 문자열 위치로 바꾼다.
rendered="$(REPORT_TITLE="$title" REPORT_TARGET="$target" REPORT_TYPE="$type_label" REPORT_CREATED="$created_date" \
  REPORT_AUTHOR="$author" REPORT_ROUND="$round" LC_ALL=C awk '
    function replace_all(text, from, to,    result, pos) {
      result = ""
      while ((pos = index(text, from)) > 0) {
        result = result substr(text, 1, pos - 1) to
        text = substr(text, pos + length(from))
      }
      return result text
    }
    {
      line = replace_all($0, "{{TITLE}}", ENVIRON["REPORT_TITLE"])
      line = replace_all(line, "{{TARGET}}", ENVIRON["REPORT_TARGET"])
      line = replace_all(line, "{{TYPE}}", ENVIRON["REPORT_TYPE"])
      line = replace_all(line, "{{DATE}}", ENVIRON["REPORT_CREATED"])
      line = replace_all(line, "{{AUTHOR}}", ENVIRON["REPORT_AUTHOR"])
      line = replace_all(line, "{{ROUND}}", ENVIRON["REPORT_ROUND"])
      print line
    }' "$template")"

mkdir -p "$date_dir" || die 1 "날짜 디렉터리를 만들지 못했습니다: $date_dir"

# 확인한 뒤 다른 작업이 같은 파일을 만들었더라도 덮어쓰지 않도록 noclobber로 쓴다.
if ! ( set -C; printf '%s\n' "$rendered" > "$report_path" ) 2>/dev/null; then
  die 1 "리뷰 보고서 파일을 만들지 못했습니다: $relative_path"
fi

log "리뷰 보고서 파일을 만들었습니다. 안내 주석에 따라 작성한 뒤 check-report.sh로 검증하세요: $relative_path"
print_result created
