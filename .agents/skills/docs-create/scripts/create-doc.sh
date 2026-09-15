#!/usr/bin/env bash
#
# docs-create 스킬 규칙에 따라 프로젝트 루트의 docs/YYMMDD/ 아래에 설계 문서 파일을 템플릿으로 만든다.
#
# 문서 경로와 파일 이름 결정, 중복 확인, 템플릿 적용을 이 스크립트가 일괄 처리하므로
# 어떤 에이전트가 실행하더라도 같은 위치에 같은 구조로 문서가 만들어진다.
# 에이전트는 만들어진 문서의 안내 주석에 따라 내용을 작성한 뒤 check-doc.sh로 검증한다.
#
# 사용법:
#   create-doc.sh <영문 문서명...> --title <문서 제목> [옵션]
#
# 예시:
#   create-doc.sh "kakao social login" --title "카카오 소셜 로그인 구현 설계" --issue 128
#
# 결과 (표준 출력, key=value 형식):
#   RESULT=created | dry-run
#   DOC_PATH=<문서 절대 경로>
#   DOC_RELATIVE_PATH=<프로젝트 루트 기준 문서 경로>
#   DOC_DATE=<YYMMDD>
#
# 종료 코드:
#   0  성공
#   1  환경 오류 (템플릿 없음, 프로젝트 루트 확인 실패, 파일 생성 실패)
#   2  인자 오류
#   3  문서명 길이 초과
#   4  같은 경로의 문서가 이미 존재
#
# 요구 사항: bash 3.2 이상, awk

set -euo pipefail

readonly MAX_NAME_LENGTH=50

log()  { printf '[docs-create] %s\n' "$*" >&2; }
warn() { printf '[docs-create] 경고: %s\n' "$*" >&2; }
die() {
  local code="$1"
  shift
  printf '[docs-create] 오류: %s\n' "$*" >&2
  exit "$code"
}

usage() {
  cat <<'EOF'
사용법: create-doc.sh <영문 문서명...> --title <문서 제목> [옵션]

옵션:
  --title <제목>       문서 제목 (필수)
  --issue <번호>       메타데이터 표의 관련 이슈에 이슈 번호를 적는다
  --author <이름>      작성자 (기본: Git 설정의 user.name)
  --root <디렉터리>    프로젝트 루트 (기본: Git 저장소 최상위 디렉터리, Git 저장소가 아니면 현재 디렉터리)
  --dry-run            문서 경로만 확인하고 파일은 만들지 않는다
  -h, --help           도움말을 출력한다

문서는 <프로젝트 루트>/docs/<YYMMDD>/<영문 문서명>.md 경로에 만든다.
EOF
}

# ---------------------------------------------------------------------------
# 인자 해석
# ---------------------------------------------------------------------------

name=""
title=""
issue=""
author=""
root=""
dry_run=false

need_value() {
  [ "$2" -ge 2 ] || die 2 "옵션에 값이 필요합니다: $1"
}

add_name_word() {
  name="${name:+$name }$1"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --title)   need_value "$1" $#; title="$2"; shift 2 ;;
    --issue)   need_value "$1" $#; issue="$2"; shift 2 ;;
    --author)  need_value "$1" $#; author="$2"; shift 2 ;;
    --root)    need_value "$1" $#; root="$2"; shift 2 ;;
    --dry-run) dry_run=true; shift ;;
    -h|--help) usage; exit 0 ;;
    --)        shift; while [ $# -gt 0 ]; do add_name_word "$1"; shift; done ;;
    -*)        die 2 "알 수 없는 옵션입니다: $1" ;;
    *)         add_name_word "$1"; shift ;;
  esac
done

# ---------------------------------------------------------------------------
# 문서명, 제목, 메타데이터 검증 (파일 시스템에 접근하지 않는 검사)
# ---------------------------------------------------------------------------

[ -n "$name" ] || { usage >&2; die 2 "영문 문서명을 입력해야 합니다."; }

# 줄바꿈과 탭은 공백으로 바꾼다.
name="$(printf '%s' "$name" | tr '\r\n\t' '   ')"
if LC_ALL=C grep -q '[^[:print:]]' <<< "$name"; then
  die 2 "문서명에 영문이 아닌 문자가 있습니다. 문서 주제를 영문으로 번역해서 전달하세요: '$name'"
fi

# 영문 소문자, 숫자, '-'만 남긴다. 확장자(.md)와 따옴표는 지우고 나머지 문자는 '-'로 바꾼다.
slug="$(printf '%s' "$name" \
  | tr '[:upper:]' '[:lower:]' \
  | sed -E 's/[[:space:]]+$//; s/\.md$//' \
  | tr -d "'\"\`" \
  | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')"
[ -n "$slug" ] || die 2 "문서명에 영문자나 숫자가 없습니다: '$name'"

if [ "${#slug}" -gt "$MAX_NAME_LENGTH" ]; then
  die 3 "문서명이 ${#slug}자로 ${MAX_NAME_LENGTH}자를 넘습니다. 핵심 키워드만 남기고 다시 실행하세요: '$slug'"
fi

# 마크다운 제목 기호(#)를 붙여 전달해도 제목 내용만 사용한다.
title="$(printf '%s' "$title" | LC_ALL=C sed -E 's/^[[:space:]]*#+[[:space:]]+//; s/^[[:space:]]+//; s/[[:space:]]+$//')"
[ -n "$title" ] || die 2 "문서 제목을 --title 옵션으로 입력해야 합니다."
if [[ "$title" == *$'\n'* || "$title" == *$'\r'* ]]; then
  die 2 "문서 제목은 한 줄로 작성해야 합니다."
fi

issue_text="-"
if [ -n "$issue" ]; then
  issue="${issue#\#}"
  [[ "$issue" =~ ^[0-9]+$ ]] || die 2 "이슈 번호는 숫자만 입력할 수 있습니다: '$issue'"
  issue_text="#$issue"
fi

author="$(printf '%s' "$author" | tr '\r\n\t' '   ' | LC_ALL=C sed -E 's/^ +//; s/ +$//')"

# ---------------------------------------------------------------------------
# 템플릿과 프로젝트 루트 확인
# ---------------------------------------------------------------------------

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
template="$script_dir/../templates/design-doc.md"
[ -f "$template" ] || die 1 "설계 문서 템플릿을 찾을 수 없습니다: $template"

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

# 날짜 디렉터리와 작성일이 어긋나지 않도록 날짜는 한 번만 구한다.
created_date="$(date +%Y-%m-%d)"
doc_date="${created_date:2:2}${created_date:5:2}${created_date:8:2}"

docs_dir="$root/docs"
date_dir="$docs_dir/$doc_date"
doc_path="$date_dir/$slug.md"
relative_path="docs/$doc_date/$slug.md"

if [ -e "$docs_dir" ] && [ ! -d "$docs_dir" ]; then
  die 1 "docs가 디렉터리가 아닌 파일로 존재합니다: $docs_dir"
fi

if [ -e "$doc_path" ] || [ -L "$doc_path" ]; then
  die 4 "같은 경로의 문서가 이미 있습니다. 기존 문서를 수정할지, 다른 문서명으로 새로 만들지 사용자에게 확인하세요: $relative_path"
fi

if [ -d "$docs_dir" ]; then
  same_name_docs="$(find "$docs_dir" -mindepth 2 -maxdepth 2 -type f -name "$slug.md" 2>/dev/null | LC_ALL=C sort || true)"
  if [ -n "$same_name_docs" ]; then
    warn "같은 이름의 문서가 다른 날짜 디렉터리에 있습니다. 새 문서를 만들지, 기존 문서를 수정할지 사용자에게 확인하세요."
    while IFS= read -r same_name_doc; do
      printf '    %s\n' "${same_name_doc#"$root"/}" >&2
    done <<< "$same_name_docs"
  fi
fi

print_result() {
  printf 'RESULT=%s\n' "$1"
  printf 'DOC_PATH=%s\n' "$doc_path"
  printf 'DOC_RELATIVE_PATH=%s\n' "$relative_path"
  printf 'DOC_DATE=%s\n' "$doc_date"
}

if [ "$dry_run" = true ]; then
  log "--dry-run 옵션에 따라 문서 파일을 만들지 않습니다."
  print_result dry-run
  exit 0
fi

# ---------------------------------------------------------------------------
# 템플릿으로 문서 생성
# ---------------------------------------------------------------------------

# 제목이나 작성자에 특수 문자가 있어도 그대로 들어가도록, 정규식 치환 대신 문자열 위치로 바꾼다.
render_template() {
  DOC_TITLE="$title" DOC_CREATED="$created_date" DOC_AUTHOR="$author" DOC_ISSUE="$issue_text" \
    LC_ALL=C awk '
      function replace_all(text, from, to,    result, pos) {
        result = ""
        while ((pos = index(text, from)) > 0) {
          result = result substr(text, 1, pos - 1) to
          text = substr(text, pos + length(from))
        }
        return result text
      }
      {
        line = replace_all($0, "{{TITLE}}", ENVIRON["DOC_TITLE"])
        line = replace_all(line, "{{DATE}}", ENVIRON["DOC_CREATED"])
        line = replace_all(line, "{{AUTHOR}}", ENVIRON["DOC_AUTHOR"])
        line = replace_all(line, "{{ISSUE}}", ENVIRON["DOC_ISSUE"])
        print line
      }' "$template"
}

rendered="$(render_template)"

mkdir -p "$date_dir" || die 1 "날짜 디렉터리를 만들지 못했습니다: $date_dir"

# 확인한 뒤 다른 작업이 같은 파일을 만들었더라도 덮어쓰지 않도록 noclobber로 쓴다.
if ! ( set -C; printf '%s\n' "$rendered" > "$doc_path" ) 2>/dev/null; then
  die 1 "문서 파일을 만들지 못했습니다: $relative_path"
fi

log "설계 문서 파일을 만들었습니다. 안내 주석에 따라 내용을 작성한 뒤 check-doc.sh로 검증하세요: $relative_path"
print_result created
