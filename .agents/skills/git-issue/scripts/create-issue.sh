#!/usr/bin/env bash
#
# git-issue 스킬 규칙에 따라 요구사항 중심의 GitHub 이슈를 생성한다.
#
# 제목과 본문 조합, 필수 섹션 검증, 라벨과 중복 이슈 확인을 이 스크립트가 일괄 처리하므로
# 어떤 에이전트가 실행하더라도 같은 구조의 이슈가 생성된다.
#
# 사용법:
#   create-issue.sh <type> <제목...> --summary <개요> --requirement <요구사항> --criteria <완료 조건> [옵션]
#
# 예시:
#   create-issue.sh feat "카카오 소셜 로그인 기능 추가" \
#     --summary "카카오 계정으로 로그인할 수 있도록 소셜 로그인 기능을 추가한다." \
#     --requirement "카카오 OAuth 인증으로 로그인할 수 있다" \
#     --criteria "카카오 계정으로 로그인하면 JWT가 발급된다" \
#     --dry-run
#
# 결과 (표준 출력, key=value 형식):
#   RESULT=created | dry-run
#   NUMBER=<이슈 번호, dry-run이면 빈 값>
#   URL=<이슈 주소, dry-run이면 빈 값>
#   REPO=<owner/repo>
#   TYPE=<type>
#   TITLE=<제목 줄>
#   LABELS=<라벨 목록, 쉼표로 구분>
#
# 종료 코드:
#   0  성공
#   1  gh 명령 실패
#   2  인자 오류
#   3  제목 줄 길이 초과
#   4  gh 미설치 또는 미인증
#   5  저장소에 없는 라벨
#   6  같은 제목의 열린 이슈 존재
#   7  대상 저장소 확인 실패
#
# 요구 사항: bash 3.2 이상, GitHub CLI(gh) 2.20 이상

set -euo pipefail

readonly ALLOWED_TYPES="feat fix refactor chore docs test"
readonly MAX_TITLE_LENGTH=72

# gh가 입력을 기다리거나 업데이트 안내를 출력하지 않도록 한다.
export GH_PROMPT_DISABLED=1
export GH_NO_UPDATE_NOTIFIER=1

log()  { printf '[git-issue] %s\n' "$*" >&2; }
warn() { printf '[git-issue] 경고: %s\n' "$*" >&2; }
die() {
  local code="$1"
  shift
  printf '[git-issue] 오류: %s\n' "$*" >&2
  exit "$code"
}

usage() {
  cat <<'EOF'
사용법: create-issue.sh <type> <제목...> --summary <개요> --requirement <요구사항> --criteria <완료 조건> [옵션]

type:
  feat | fix | refactor | chore | docs | test

본문 옵션:
  --summary <내용>        개요 (필수)
  --requirement <내용>    요구사항 한 항목 (1개 이상 필수, 여러 번 지정 가능)
  --criteria <내용>       완료 조건 한 항목 (1개 이상 필수, 여러 번 지정 가능)
  --step <내용>           재현 방법 한 단계 (fix 전용, 여러 번 지정 가능)
  --expected <내용>       기대 동작 (fix 전용)
  --actual <내용>         실제 동작 (fix 전용)
  --note <내용>           참고 사항 한 항목 (여러 번 지정 가능)

이슈 옵션:
  --label <이름>          라벨 추가 (여러 번 지정 가능)
  --assignee <사용자>     담당자 지정 (@me 가능, 여러 번 지정 가능)
  --milestone <이름>      마일스톤 지정
  --repo <owner/repo>     대상 저장소 (기본: 현재 디렉터리의 저장소)
  --allow-duplicate       같은 제목의 열린 이슈가 있어도 생성한다 (사용자 승인 필요)
  --dry-run               검증과 본문 미리보기만 수행하고 이슈를 생성하지 않는다
  -h, --help              도움말을 출력한다
EOF
}

# UTF-8 연속 바이트(0x80-0xBF)를 빼고 바이트 수를 세서 글자 수를 구한다. 로케일 설정과 관계없이 동작한다.
char_count() {
  printf '%s' "$1" | LC_ALL=C tr -d '\200-\277' | wc -c | tr -d ' '
}

trim() {
  printf '%s' "$1" | LC_ALL=C sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//'
}

# 변수 이름($1)이 가리키는 목록에 값($2)을 한 줄로 추가한다.
append_value() {
  if [ -z "${!1}" ]; then
    printf -v "$1" '%s' "$2"
  else
    printf -v "$1" '%s\n%s' "${!1}" "$2"
  fi
}

check_single_line() {
  [ -n "$2" ] || die 2 "옵션 값이 비어 있습니다: $1"
  if [[ "$2" == *$'\n'* || "$2" == *$'\r'* ]]; then
    die 2 "한 줄로 작성해야 하는 옵션입니다: $1"
  fi
}

# 본문 목록 항목을 추가한다. 에이전트가 붙인 목록 기호('- [ ] ', '- ', '1. ')는 제거한다.
add_item() {
  local value
  value="$(trim "$3" | LC_ALL=C sed -E 's/^(- \[[ xX]\] |[-*] |[0-9]+\. )//')"
  check_single_line "$2" "$value"
  append_value "$1" "$value"
}

# 라벨, 담당자처럼 이름 그대로 사용하는 값을 추가한다.
add_name() {
  local value
  value="$(trim "$3")"
  check_single_line "$2" "$value"
  append_value "$1" "$value"
}

# 여러 줄을 허용하는 값을 한 번만 지정할 수 있도록 설정한다.
set_text() {
  local value
  [ -z "${!1}" ] || die 2 "한 번만 지정할 수 있는 옵션입니다: $2"
  value="$(printf '%s' "$3" | tr -d '\r')"
  [ -n "$(printf '%s' "$value" | tr -d '[:space:]')" ] || die 2 "옵션 값이 비어 있습니다: $2"
  printf -v "$1" '%s' "$value"
}

# ---------------------------------------------------------------------------
# 인자 해석
# ---------------------------------------------------------------------------

type=""
title=""
summary=""
requirements=""
criteria=""
steps=""
expected=""
actual=""
notes=""
labels=""
assignees=""
milestone=""
repo=""
allow_duplicate=false
dry_run=false

need_value() {
  [ "$2" -ge 2 ] || die 2 "옵션에 값이 필요합니다: $1"
}

# 첫 번째 위치 인자는 type, 나머지는 공백으로 이어 붙여 제목으로 사용한다.
add_positional() {
  if [ -z "$type" ]; then
    type="$1"
  else
    title="${title:+$title }$1"
  fi
}

while [ $# -gt 0 ]; do
  case "$1" in
    --summary)         need_value "$1" $#; set_text summary "$1" "$2"; shift 2 ;;
    --requirement)     need_value "$1" $#; add_item requirements "$1" "$2"; shift 2 ;;
    --criteria)        need_value "$1" $#; add_item criteria "$1" "$2"; shift 2 ;;
    --step)            need_value "$1" $#; add_item steps "$1" "$2"; shift 2 ;;
    --expected)        need_value "$1" $#; set_text expected "$1" "$2"; shift 2 ;;
    --actual)          need_value "$1" $#; set_text actual "$1" "$2"; shift 2 ;;
    --note)            need_value "$1" $#; add_item notes "$1" "$2"; shift 2 ;;
    --label)           need_value "$1" $#; add_name labels "$1" "$2"; shift 2 ;;
    --assignee)        need_value "$1" $#; add_name assignees "$1" "$2"; shift 2 ;;
    --milestone)       need_value "$1" $#; set_text milestone "$1" "$2"; shift 2 ;;
    --repo)            need_value "$1" $#; set_text repo "$1" "$2"; shift 2 ;;
    --allow-duplicate) allow_duplicate=true; shift ;;
    --dry-run)         dry_run=true; shift ;;
    -h|--help)         usage; exit 0 ;;
    --)                shift; while [ $# -gt 0 ]; do add_positional "$1"; shift; done ;;
    -*)                die 2 "알 수 없는 옵션입니다: $1" ;;
    *)                 add_positional "$1"; shift ;;
  esac
done

# ---------------------------------------------------------------------------
# 제목과 본문 검증 (GitHub에 접근하지 않는 검사)
# ---------------------------------------------------------------------------

[ -n "$type" ] || { usage >&2; die 2 "type을 입력해야 합니다."; }

# 'feat:', '[feat]' 형식으로 전달해도 type 이름만 사용한다.
type="$(printf '%s' "$type" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
type="${type%:}"
type="${type#\[}"
type="${type%\]}"
[[ "$type" =~ ^[a-z]+$ ]] || die 2 "허용되지 않는 type입니다: '$type' (허용: $ALLOWED_TYPES)"
case " $ALLOWED_TYPES " in
  *" $type "*) ;;
  *) die 2 "허용되지 않는 type입니다: '$type' (허용: $ALLOWED_TYPES)" ;;
esac

title="$(trim "$title")"
[ -n "$title" ] || die 2 "이슈 제목을 입력해야 합니다."
if [[ "$title" == *$'\n'* || "$title" == *$'\r'* ]]; then
  die 2 "제목은 한 줄로 작성해야 합니다. 자세한 내용은 --summary 옵션으로 전달하세요."
fi

lower_title="$(printf '%s' "$title" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
for allowed in $ALLOWED_TYPES; do
  case "$lower_title" in
    "[$allowed]"*|"$allowed":*) die 2 "제목에는 type을 빼고 전달하세요: '$title'" ;;
  esac
done

case "$title" in
  *.|*。) die 2 "제목 끝에 마침표를 찍지 않습니다: '$title'" ;;
esac

full_title="$type: $title"
title_length="$(char_count "$full_title")"
if [ "$title_length" -gt "$MAX_TITLE_LENGTH" ]; then
  die 3 "제목 줄이 ${title_length}자로 ${MAX_TITLE_LENGTH}자를 넘습니다. 제목을 줄이고 자세한 내용은 --summary 옵션으로 옮기세요: '$full_title'"
fi

[ -n "$summary" ] || die 2 "개요를 --summary 옵션으로 입력해야 합니다."
[ -n "$requirements" ] || die 2 "요구사항을 --requirement 옵션으로 1개 이상 입력해야 합니다."
[ -n "$criteria" ] || die 2 "완료 조건을 --criteria 옵션으로 1개 이상 입력해야 합니다."

if [ "$type" != fix ] && [ -n "$steps$expected$actual" ]; then
  die 2 "--step, --expected, --actual 옵션은 fix 이슈에서만 사용할 수 있습니다."
fi

if [ -n "$repo" ]; then
  repo_pattern='^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+){1,2}$'
  [[ "$repo" =~ $repo_pattern ]] || die 2 "저장소는 owner/repo 형식으로 입력해야 합니다: '$repo'"
fi

# 줄바꿈으로 구분한 항목($1)을 지정한 형식($2: checkbox, bullet, number)의 목록으로 출력한다.
format_list() {
  local index=0 item
  while IFS= read -r item; do
    index=$((index + 1))
    case "$2" in
      checkbox) printf -- '- [ ] %s\n' "$item" ;;
      bullet)   printf -- '- %s\n' "$item" ;;
      number)   printf '%d. %s\n' "$index" "$item" ;;
    esac
  done <<< "$1"
}

build_body() {
  printf '## 개요\n%s\n' "$summary"
  if [ -n "$steps" ]; then
    printf '\n## 재현 방법\n'
    format_list "$steps" number
  fi
  if [ -n "$expected" ]; then
    printf '\n## 기대 동작\n%s\n' "$expected"
  fi
  if [ -n "$actual" ]; then
    printf '\n## 실제 동작\n%s\n' "$actual"
  fi
  printf '\n## 요구사항\n'
  format_list "$requirements" checkbox
  printf '\n## 완료 조건\n'
  format_list "$criteria" checkbox
  if [ -n "$notes" ]; then
    printf '\n## 참고 사항\n'
    format_list "$notes" bullet
  fi
}

body="$(build_body)"

# ---------------------------------------------------------------------------
# GitHub CLI와 대상 저장소 확인
# ---------------------------------------------------------------------------

command -v gh >/dev/null 2>&1 || die 4 "GitHub CLI(gh)가 설치되어 있지 않습니다. 사용자에게 설치를 요청하세요."

err_file="$(mktemp "${TMPDIR:-/tmp}/git-issue.XXXXXX")"
trap 'rm -f "$err_file"' EXIT

if ! gh auth status >/dev/null 2>"$err_file"; then
  die 4 "GitHub CLI 인증이 필요합니다. 사용자에게 gh auth login 실행을 요청하세요.
$(cat "$err_file")"
fi

if ! repo_info="$(gh repo view ${repo:+"$repo"} --json nameWithOwner,visibility --jq '.nameWithOwner + " " + .visibility' 2>"$err_file")"; then
  die 7 "대상 저장소를 확인할 수 없습니다. GitHub 원격 저장소가 연결되어 있는지 확인하거나 --repo 옵션으로 지정하세요.
$(cat "$err_file")"
fi
repo_name="${repo_info% *}"
visibility="${repo_info##* }"
[ -n "$repo_name" ] || die 7 "대상 저장소 이름을 확인할 수 없습니다."

if [ "$visibility" = PUBLIC ]; then
  warn "공개 저장소입니다. 이슈 내용이 외부에 공개됩니다: $repo_name"
fi

# ---------------------------------------------------------------------------
# 라벨 확인
# ---------------------------------------------------------------------------

if ! repo_labels="$(gh label list -R "$repo_name" --limit 1000 --json name --jq '.[].name' 2>"$err_file")"; then
  die 1 "라벨 목록을 조회하지 못했습니다.
$(cat "$err_file")"
fi

resolved_labels=""

# 저장소에 등록된 이름으로 라벨을 중복 없이 추가한다.
add_resolved_label() {
  if [ -z "$resolved_labels" ] || ! grep -Fxiq -- "$1" <<< "$resolved_labels"; then
    append_value resolved_labels "$1"
  fi
}

case "$type" in
  feat) default_label=enhancement ;;
  fix)  default_label=bug ;;
  docs) default_label=documentation ;;
  *)    default_label="" ;;
esac

if matched="$(grep -Fxi -m 1 -- "$type" <<< "$repo_labels")"; then
  add_resolved_label "$matched"
elif [ -n "$default_label" ] && matched="$(grep -Fxi -m 1 -- "$default_label" <<< "$repo_labels")"; then
  add_resolved_label "$matched"
fi

missing_labels=""
if [ -n "$labels" ]; then
  while IFS= read -r label; do
    if matched="$(grep -Fxi -m 1 -- "$label" <<< "$repo_labels")"; then
      add_resolved_label "$matched"
    else
      missing_labels="${missing_labels:+$missing_labels, }$label"
    fi
  done <<< "$labels"
fi

if [ -n "$missing_labels" ]; then
  log "저장소에 등록된 라벨:"
  printf '%s\n' "${repo_labels:-(없음)}" | LC_ALL=C sed 's/^/    /' >&2
  die 5 "저장소에 없는 라벨입니다: $missing_labels. 사용할 라벨을 사용자에게 확인하세요."
fi

labels_csv="$(printf '%s' "$resolved_labels" | tr '\n' ',')"

# ---------------------------------------------------------------------------
# 중복 이슈 확인
# ---------------------------------------------------------------------------

# 검색 문법으로 해석될 수 있는 문자를 공백으로 바꾼다.
search_words="$(printf '%s' "$title" | tr '"():' '    ' | LC_ALL=C sed -E 's/(^|[[:space:]])-+/\1/g')"
if ! open_issues="$(gh issue list -R "$repo_name" --state open --search "$search_words in:title" --limit 20 \
  --json number,title,url --jq '.[] | "\(.number)\t\(.title)\t\(.url)"' 2>"$err_file")"; then
  die 1 "열린 이슈 목록을 조회하지 못했습니다.
$(cat "$err_file")"
fi

duplicate=""
similar_issues=""
while IFS=$'\t' read -r number issue_title url; do
  [ -n "$number" ] || continue
  if [ "$issue_title" = "$full_title" ]; then
    duplicate="#$number $url"
  else
    similar_issues="$similar_issues    #$number $issue_title ($url)"$'\n'
  fi
done <<< "$open_issues"

if [ -n "$duplicate" ]; then
  if [ "$allow_duplicate" = false ]; then
    die 6 "같은 제목의 열린 이슈가 이미 있습니다: $duplicate. 기존 이슈를 사용할지 사용자에게 확인하고, 새로 만들려면 --allow-duplicate 옵션을 추가하세요."
  fi
  warn "--allow-duplicate 옵션에 따라 같은 제목의 이슈를 새로 생성합니다. 기존 이슈: $duplicate"
fi

if [ -n "$similar_issues" ]; then
  warn "제목이 비슷한 열린 이슈가 있습니다. 중복 여부를 사용자에게 알리세요."
  printf '%s' "$similar_issues" >&2
fi

# ---------------------------------------------------------------------------
# 미리보기와 이슈 생성
# ---------------------------------------------------------------------------

print_result() {
  printf 'RESULT=%s\n' "$1"
  printf 'NUMBER=%s\n' "$2"
  printf 'URL=%s\n' "$3"
  printf 'REPO=%s\n' "$repo_name"
  printf 'TYPE=%s\n' "$type"
  printf 'TITLE=%s\n' "$full_title"
  printf 'LABELS=%s\n' "$labels_csv"
}

log "이슈 미리보기:"
{
  printf '    제목: %s\n' "$full_title"
  printf '    저장소: %s\n' "$repo_name"
  printf '    라벨: %s\n' "${labels_csv:-(없음)}"
  if [ -n "$assignees" ]; then
    printf '    담당자: %s\n' "$(printf '%s' "$assignees" | tr '\n' ',')"
  fi
  if [ -n "$milestone" ]; then
    printf '    마일스톤: %s\n' "$milestone"
  fi
  printf '    ----------------------------------------\n'
  printf '%s\n' "$body" | LC_ALL=C sed 's/^/    /'
} >&2

if [ "$dry_run" = true ]; then
  log "--dry-run 옵션에 따라 이슈를 생성하지 않습니다."
  print_result dry-run "" ""
  exit 0
fi

create_args=(issue create -R "$repo_name" --title "$full_title" --body-file -)
while IFS= read -r label; do
  if [ -n "$label" ]; then
    create_args+=(--label "$label")
  fi
done <<< "$resolved_labels"
while IFS= read -r assignee; do
  if [ -n "$assignee" ]; then
    create_args+=(--assignee "$assignee")
  fi
done <<< "$assignees"
if [ -n "$milestone" ]; then
  create_args+=(--milestone "$milestone")
fi

log "이슈를 생성합니다: $full_title"
if ! create_output="$(printf '%s\n' "$body" | gh "${create_args[@]}" 2>"$err_file")"; then
  die 1 "이슈를 생성하지 못했습니다.
$(cat "$err_file")"
fi

issue_url="$(printf '%s\n' "$create_output" | grep -E '^https?://' | tail -n 1 || true)"
[ -n "$issue_url" ] || die 1 "이슈 주소를 확인하지 못했습니다. 이슈가 생성되었는지 GitHub에서 확인하세요.
$create_output"

print_result created "${issue_url##*/}" "$issue_url"
