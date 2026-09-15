#!/usr/bin/env bash
#
# deliverable-review 스킬 규칙에 따라 리뷰 보고서의 경로, 목차, 작성 여부, 결론과 심각도의 일관성을 검증한다.
#
# 필수 목차는 templates/review-report.md에서 읽는다. 템플릿의 목차를 바꾸면 검증 기준도 함께 바뀐다.
#
# 사용법:
#   check-report.sh <리뷰 보고서 경로>
#
# 결과 (표준 출력, key=value 형식):
#   RESULT=valid | invalid
#   REPORT_PATH=<보고서 절대 경로>
#   VERDICT=<결론>
#   HIGH=<심각도 높음 지적 사항 수>
#   MEDIUM=<심각도 중간 지적 사항 수>
#   LOW=<심각도 낮음 지적 사항 수>
#   ISSUES=<발견한 문제 수>
#
# 종료 코드:
#   0  규칙에 맞는 보고서
#   1  보고서 파일이나 템플릿을 찾을 수 없음
#   2  인자 오류
#   3  보고서 규칙 위반
#
# 요구 사항: bash 3.2 이상, awk

set -euo pipefail

readonly GUIDE_MARKER='<!-- deliverable-review:'
readonly MAX_NAME_LENGTH=50

log() { printf '[deliverable-review] %s\n' "$*" >&2; }
die() {
  local code="$1"
  shift
  printf '[deliverable-review] 오류: %s\n' "$*" >&2
  exit "$code"
}

usage() {
  cat <<'EOF'
사용법: check-report.sh <리뷰 보고서 경로>

리뷰 보고서가 deliverable-review 스킬 규칙에 맞는지 검증한다.
  - 경로가 docs/<YYMMDD>/<영문 대상명>-<doc|code>-review(-<차수>).md 규칙에 맞는지
  - 보고서 제목(#)이 한 개이고, 템플릿의 필수 섹션이 순서대로 작성되었는지
  - 안내 주석이나 채우지 않은 템플릿 항목({{...}})이 남아 있지 않은지
  - 리뷰 일자, 대상 유형, 결론이 규칙에 맞는지
  - 지적 사항의 심각도와 결론이 결론 기준에 맞는지
EOF
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac
[ $# -eq 1 ] || { usage >&2; die 2 "검증할 리뷰 보고서 경로를 하나만 입력해야 합니다."; }

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
template="$script_dir/../templates/review-report.md"
[ -f "$template" ] || die 1 "리뷰 보고서 템플릿을 찾을 수 없습니다: $template"

report="$1"
[ -f "$report" ] || die 1 "리뷰 보고서 파일을 찾을 수 없습니다: $report"
[ -r "$report" ] || die 1 "리뷰 보고서 파일을 읽을 수 없습니다: $report"
report_path="$(cd "$(dirname "$report")" && pwd)/$(basename "$report")"

issues=""
add_issue() {
  issues="$issues$1"$'\n'
}

# ---------------------------------------------------------------------------
# 경로 규칙: docs/<YYMMDD>/<영문 대상명>-<doc|code>-review(-<차수>).md
# ---------------------------------------------------------------------------

file_name="$(basename "$report_path")"
date_dir_path="$(dirname "$report_path")"
date_dir="$(basename "$date_dir_path")"
docs_dir="$(basename "$(dirname "$date_dir_path")")"

[ "$docs_dir" = docs ] || add_issue "보고서가 docs/<YYMMDD>/ 디렉터리 아래에 있지 않습니다."

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

file_type=""
name_pattern='^([a-z0-9]+(-[a-z0-9]+)*)-(doc|code)-review(-[0-9]+)?\.md$'
if [[ "$file_name" =~ $name_pattern ]]; then
  base_name="${BASH_REMATCH[1]}"
  file_type="${BASH_REMATCH[3]}"
  if [ "${#base_name}" -gt "$MAX_NAME_LENGTH" ]; then
    add_issue "영문 대상명이 ${MAX_NAME_LENGTH}자를 넘습니다: $file_name"
  fi
else
  add_issue "보고서 파일 이름은 <영문 대상명>-<doc|code>-review(-<차수>).md 형식이어야 합니다: $file_name"
fi

# ---------------------------------------------------------------------------
# 메타데이터와 템플릿 항목
# ---------------------------------------------------------------------------

metadata_value() {
  local value
  value="$(LC_ALL=C sed -n "s/^| *$1 *| *\\([^|]*[^ |]\\) *|.*\$/\\1/p" "$report_path")"
  printf '%s' "${value%%$'\n'*}"
}

review_date="$(metadata_value '리뷰 일자')"
if [ -z "$review_date" ]; then
  add_issue "메타데이터 표에 리뷰 일자가 없습니다."
elif [ -n "$expected_date" ] && [ "$review_date" != "$expected_date" ]; then
  add_issue "메타데이터의 리뷰 일자($review_date)가 날짜 디렉터리($date_dir)와 다릅니다."
fi

type_value="$(metadata_value '대상 유형')"
if [ -z "$type_value" ]; then
  add_issue "메타데이터 표에 대상 유형이 없습니다."
else
  case "$file_type:$type_value" in
    "doc:설계 문서"|"code:코드 변경"|:*) ;;
    *) add_issue "메타데이터의 대상 유형($type_value)이 파일 이름의 대상 유형($file_type)과 맞지 않습니다." ;;
  esac
fi

verdict="$(metadata_value 결론)"
verdict_valid=false
case "$verdict" in
  승인|"조건부 승인"|"수정 필요") verdict_valid=true ;;
  "검토 중") add_issue "결론이 아직 검토 중입니다. 승인, 조건부 승인, 수정 필요 중 하나로 바꾸세요." ;;
  "")        add_issue "메타데이터 표에 결론이 없습니다." ;;
  *)         add_issue "결론은 승인, 조건부 승인, 수정 필요 중 하나여야 합니다: $verdict" ;;
esac

if LC_ALL=C grep -q '{{[A-Z_]*}}' "$report_path"; then
  add_issue "채우지 않은 템플릿 항목({{...}})이 남아 있습니다."
fi

# ---------------------------------------------------------------------------
# 목차와 작성 여부
# ---------------------------------------------------------------------------

required_headings="$(LC_ALL=C grep -E '^#{2,6} ' "$template" || true)"

# 셸의 readonly 변수와 이름이 겹치지 않도록 awk에 넘기는 환경 변수에는 REPORT_ 접두어를 붙인다.
structure_issues="$(REPORT_REQUIRED_HEADINGS="$required_headings" REPORT_GUIDE_MARKER="$GUIDE_MARKER" LC_ALL=C awk '
  function trim(s) {
    sub(/^[ \t]+/, "", s)
    sub(/[ \t\r]+$/, "", s)
    return s
  }
  BEGIN {
    required_count = split(ENVIRON["REPORT_REQUIRED_HEADINGS"], required, "\n")
    marker = ENVIRON["REPORT_GUIDE_MARKER"]
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
    if (titles != 1) printf "보고서 제목(# 제목)은 한 개여야 합니다. (현재 %d개)\n", titles
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
  }' "$report_path")"

if [ -n "$structure_issues" ]; then
  issues="$issues$structure_issues"$'\n'
fi

# ---------------------------------------------------------------------------
# 지적 사항의 심각도와 결론
# ---------------------------------------------------------------------------

# 제목($1)부터 같은 수준 이상의 다음 제목 전까지의 본문을 출력한다.
section_body() {
  REPORT_SECTION="$1" LC_ALL=C awk '
    function level_of(text) {
      match(text, /^#+/)
      return RLENGTH
    }
    {
      if ($0 ~ /^[ \t]*(```|~~~)/) in_code = !in_code
      if (!in_code && $0 ~ /^#+ /) {
        if (inside && level_of($0) <= target_level) exit
        if ($0 == ENVIRON["REPORT_SECTION"]) {
          inside = 1
          target_level = level_of($0)
          next
        }
      }
      if (inside) print
    }' "$report_path"
}

# 표의 두 번째 칸(심각도)을 세고, "없음"으로 작성했는지 확인한다.
severity_summary="$(section_body '## 3. 지적 사항' | LC_ALL=C awk -F'|' '
  function trim(s) {
    sub(/^[ \t]+/, "", s)
    sub(/[ \t\r]+$/, "", s)
    return s
  }
  /^[ \t]*\|/ {
    if ($0 ~ /^[ \t]*\|[ \t:|-]+\|[ \t]*$/) next
    severity = trim($3)
    if (severity == "심각도") next
    rows++
    if (severity == "높음") high++
    else if (severity == "중간") medium++
    else if (severity == "낮음") low++
    else invalid = invalid (invalid == "" ? "" : ", ") severity
    next
  }
  {
    text = trim($0)
    sub(/^[-*][ \t]+/, "", text)
    if (text == "없음" || text == "없음.") none = 1
  }
  END { printf "%d %d %d %d %d %s\n", high, medium, low, rows, none, invalid }')"

read -r high medium low rows none invalid_severities <<< "$severity_summary"

if [ "$rows" -eq 0 ] && [ "$none" -eq 0 ]; then
  add_issue "3. 지적 사항은 표(| 번호 | 심각도 | 위치 | 내용 | 제안 |)나 '없음'으로 작성해야 합니다."
fi
if [ -n "$invalid_severities" ]; then
  add_issue "지적 사항의 심각도는 높음, 중간, 낮음 중 하나여야 합니다: $invalid_severities"
fi

if [ "$verdict_valid" = true ]; then
  if [ "$high" -gt 0 ] && [ "$verdict" != "수정 필요" ]; then
    add_issue "심각도 높음 지적 사항이 ${high}개 있으므로 결론은 수정 필요여야 합니다. (현재 결론: $verdict)"
  elif [ "$verdict" = 승인 ] && [ "$medium" -gt 0 ]; then
    add_issue "심각도 중간 지적 사항이 ${medium}개 있으므로 결론을 승인으로 할 수 없습니다."
  fi
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
  printf 'REPORT_PATH=%s\n' "$report_path"
  printf 'VERDICT=%s\n' "${verdict:--}"
  printf 'HIGH=%s\n' "$high"
  printf 'MEDIUM=%s\n' "$medium"
  printf 'LOW=%s\n' "$low"
  printf 'ISSUES=%s\n' "$issue_count"
}

if [ "$issue_count" -eq 0 ]; then
  log "리뷰 보고서가 deliverable-review 규칙에 맞습니다: $report_path"
  print_result valid
  exit 0
fi

log "리뷰 보고서 규칙에 맞지 않는 부분 (${issue_count}개):"
printf '%s' "$issues" | LC_ALL=C sed '/^$/d; s/^/    - /' >&2
print_result invalid
exit 3
