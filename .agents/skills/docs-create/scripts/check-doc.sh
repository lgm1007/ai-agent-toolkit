#!/usr/bin/env bash
#
# docs-create 스킬 규칙에 따라 설계 문서의 경로, 목차, 작성 여부, 메타데이터를 검증한다.
#
# 필수 목차는 templates/design-doc.md에서 읽는다. 템플릿의 목차를 바꾸면 검증 기준도 함께 바뀐다.
#
# 사용법:
#   check-doc.sh <문서 경로>
#
# 결과 (표준 출력, key=value 형식):
#   RESULT=valid | invalid
#   DOC_PATH=<문서 절대 경로>
#   ISSUES=<발견한 문제 수>
#
# 종료 코드:
#   0  규칙에 맞는 문서
#   1  문서 파일이나 템플릿을 찾을 수 없음
#   2  인자 오류
#   3  문서 규칙 위반
#
# 요구 사항: bash 3.2 이상, awk

set -euo pipefail

readonly GUIDE_MARKER='<!-- docs-create:'
readonly MAX_NAME_LENGTH=50

log() { printf '[docs-create] %s\n' "$*" >&2; }
die() {
  local code="$1"
  shift
  printf '[docs-create] 오류: %s\n' "$*" >&2
  exit "$code"
}

usage() {
  cat <<'EOF'
사용법: check-doc.sh <문서 경로>

설계 문서가 docs-create 스킬 규칙에 맞는지 검증한다.
  - 문서 경로가 docs/<YYMMDD>/<영문 문서명>.md 규칙에 맞는지
  - 문서 제목(#)이 한 개인지
  - 템플릿의 필수 섹션이 모두 같은 순서로 있고, 각 섹션에 내용이 작성되었는지
  - 안내 주석이나 채우지 않은 템플릿 항목({{...}})이 남아 있지 않은지
  - 메타데이터의 작성일이 날짜 디렉터리와 같고, 상태가 초안, 검토 중, 확정 중 하나인지
EOF
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac
[ $# -eq 1 ] || { usage >&2; die 2 "검증할 문서 경로를 하나만 입력해야 합니다."; }

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
template="$script_dir/../templates/design-doc.md"
[ -f "$template" ] || die 1 "설계 문서 템플릿을 찾을 수 없습니다: $template"

doc="$1"
[ -f "$doc" ] || die 1 "문서 파일을 찾을 수 없습니다: $doc"
[ -r "$doc" ] || die 1 "문서 파일을 읽을 수 없습니다: $doc"
doc_path="$(cd "$(dirname "$doc")" && pwd)/$(basename "$doc")"

issues=""
add_issue() {
  issues="$issues$1"$'\n'
}

# ---------------------------------------------------------------------------
# 경로 규칙: docs/<YYMMDD>/<영문 문서명>.md
# ---------------------------------------------------------------------------

file_name="$(basename "$doc_path")"
date_dir_path="$(dirname "$doc_path")"
date_dir="$(basename "$date_dir_path")"
docs_dir="$(basename "$(dirname "$date_dir_path")")"

[ "$docs_dir" = docs ] || add_issue "문서가 docs/<YYMMDD>/ 디렉터리 아래에 있지 않습니다."

expected_date=""
date_pattern='^[0-9]{6}$'
if [[ "$date_dir" =~ $date_pattern ]]; then
  month=$((10#${date_dir:2:2}))
  day=$((10#${date_dir:4:2}))
  if [ "$month" -ge 1 ] && [ "$month" -le 12 ] && [ "$day" -ge 1 ] && [ "$day" -le 31 ]; then
    expected_date="20${date_dir:0:2}-${date_dir:2:2}-${date_dir:4:2}"
  else
    add_issue "날짜 디렉터리가 올바른 날짜가 아닙니다: $date_dir"
  fi
else
  add_issue "날짜 디렉터리 이름이 YYMMDD 형식이 아닙니다: $date_dir"
fi

name_pattern='^[a-z0-9]+(-[a-z0-9]+)*\.md$'
if [[ "$file_name" =~ $name_pattern ]]; then
  base_name="${file_name%.md}"
  if [ "${#base_name}" -gt "$MAX_NAME_LENGTH" ]; then
    add_issue "문서명이 ${MAX_NAME_LENGTH}자를 넘습니다: $file_name"
  fi
else
  add_issue "문서 파일 이름은 영문 소문자, 숫자, '-'로 구성한 .md 파일이어야 합니다: $file_name"
fi

# ---------------------------------------------------------------------------
# 메타데이터와 템플릿 항목
# ---------------------------------------------------------------------------

metadata_value() {
  local value
  value="$(LC_ALL=C sed -n "s/^| *$1 *| *\\([^|]*[^ |]\\) *|.*\$/\\1/p" "$doc_path")"
  printf '%s' "${value%%$'\n'*}"
}

created="$(metadata_value 작성일)"
if [ -z "$created" ]; then
  add_issue "메타데이터 표에 작성일이 없습니다."
elif [ -n "$expected_date" ] && [ "$created" != "$expected_date" ]; then
  add_issue "메타데이터의 작성일($created)이 날짜 디렉터리($date_dir)와 다릅니다."
fi

status="$(metadata_value 상태)"
case "$status" in
  초안|"검토 중"|확정) ;;
  "") add_issue "메타데이터 표에 상태가 없습니다." ;;
  *)  add_issue "메타데이터의 상태는 초안, 검토 중, 확정 중 하나여야 합니다: $status" ;;
esac

if LC_ALL=C grep -q '{{[A-Z_]*}}' "$doc_path"; then
  add_issue "채우지 않은 템플릿 항목({{...}})이 남아 있습니다."
fi

# ---------------------------------------------------------------------------
# 목차와 작성 여부
# ---------------------------------------------------------------------------

required_headings="$(LC_ALL=C grep -E '^#{2,6} ' "$template" || true)"

# 코드 블록과 HTML 주석 안의 줄은 제목으로 보지 않는다.
# 필수 섹션은 템플릿과 같은 순서로 있어야 하며, 같은 수준 이상의 다음 제목 전까지 내용이 한 줄 이상 있어야 한다.
# 셸의 readonly 변수와 이름이 겹치지 않도록 awk에 넘기는 환경 변수에는 DOC_ 접두어를 붙인다.
structure_issues="$(DOC_REQUIRED_HEADINGS="$required_headings" DOC_GUIDE_MARKER="$GUIDE_MARKER" LC_ALL=C awk '
  function trim(s) {
    sub(/^[ \t]+/, "", s)
    sub(/[ \t\r]+$/, "", s)
    return s
  }
  BEGIN {
    required_count = split(ENVIRON["DOC_REQUIRED_HEADINGS"], required, "\n")
    marker = ENVIRON["DOC_GUIDE_MARKER"]
  }
  {
    text = trim($0)
    if (in_code) {
      kind[NR] = "content"
      if (text ~ /^(```|~~~)/) in_code = 0
      next
    }
    if (text ~ /^(```|~~~)/) {
      in_code = 1
      kind[NR] = "content"
      next
    }
    if (marker != "" && index(text, marker) > 0) markers++
    if (in_comment) {
      kind[NR] = "empty"
      if (index(text, "-->") > 0) in_comment = 0
      next
    }
    if (substr(text, 1, 4) == "<!--") {
      kind[NR] = "empty"
      if (index(text, "-->") == 0) in_comment = 1
      next
    }
    if (text == "") {
      kind[NR] = "empty"
      next
    }
    if (text ~ /^#+ /) {
      match(text, /^#+/)
      kind[NR] = "heading"
      level[NR] = RLENGTH
      heading[NR] = text
      if (RLENGTH == 1) titles++
      next
    }
    kind[NR] = "content"
  }
  END {
    if (titles != 1) printf "문서 제목(# 제목)은 한 개여야 합니다. (현재 %d개)\n", titles
    if (markers > 0) printf "작성하지 않은 안내 주석이 %d개 남아 있습니다.\n", markers
    start = 1
    for (r = 1; r <= required_count; r++) {
      want = trim(required[r])
      if (want == "") continue
      found = 0
      for (i = start; i <= NR; i++) {
        if (kind[i] == "heading" && heading[i] == want) {
          found = i
          break
        }
      }
      if (!found) {
        printf "필수 섹션이 없거나 순서가 다릅니다: %s\n", want
        continue
      }
      start = found + 1
      has_content = 0
      for (j = found + 1; j <= NR; j++) {
        if (kind[j] == "heading" && level[j] <= level[found]) break
        if (kind[j] == "content") {
          has_content = 1
          break
        }
      }
      if (!has_content) printf "섹션 내용이 비어 있습니다: %s\n", want
    }
  }' "$doc_path")"

if [ -n "$structure_issues" ]; then
  issues="$issues$structure_issues"$'\n'
fi

# ---------------------------------------------------------------------------
# 결과 출력
# ---------------------------------------------------------------------------

issue_count=0
if [ -n "$issues" ]; then
  issue_count="$(printf '%s' "$issues" | grep -c . || true)"
fi

print_result() {
  printf 'RESULT=%s\n' "$1"
  printf 'DOC_PATH=%s\n' "$doc_path"
  printf 'ISSUES=%s\n' "$issue_count"
}

if [ "$issue_count" -eq 0 ]; then
  log "문서가 docs-create 규칙에 맞습니다: $doc_path"
  print_result valid
  exit 0
fi

log "문서 규칙에 맞지 않는 부분 (${issue_count}개):"
printf '%s' "$issues" | LC_ALL=C sed '/^$/d; s/^/    - /' >&2
print_result invalid
exit 3
