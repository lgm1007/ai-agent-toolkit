#!/usr/bin/env bash
#
# git-commit 스킬 규칙에 따라 스테이징한 변경 사항을 커밋한다.
#
# 메시지 조합과 검증, 브랜치와 스테이징 상태 확인을 이 스크립트가 일괄 처리하므로
# 어떤 에이전트가 실행하더라도 같은 형식의 커밋이 생성된다.
#
# 사용법:
#   commit.sh <type> <제목...> [옵션]
#
# 예시:
#   commit.sh feat "카카오 소셜 로그인 API 추가"
#   commit.sh fix "주문 취소 오류 수정" --body "- 취소할 주문이 없으면 404 응답을 반환"
#
# 결과 (표준 출력, key=value 형식):
#   RESULT=committed | dry-run
#   COMMIT=<커밋 해시, dry-run이면 빈 값>
#   BRANCH=<브랜치명>
#   HEADER=<제목 줄>
#   FILES=<커밋에 포함된 파일 수>
#
# 종료 코드:
#   0  성공
#   1  저장소 상태 오류 또는 커밋 실패
#   2  인자 오류
#   3  제목 줄 길이 초과
#   4  보호 브랜치에 직접 커밋
#   5  스테이징한 변경 사항 없음
#   6  민감한 파일로 의심되는 파일 스테이징
#
# 요구 사항: bash 3.2 이상, git 2.23 이상

set -euo pipefail

readonly ALLOWED_TYPES="feat fix refactor chore docs test"
readonly PROTECTED_BRANCHES="main master develop dev development"
readonly MAX_HEADER_LENGTH=72

log()  { printf '[git-commit] %s\n' "$*" >&2; }
warn() { printf '[git-commit] 경고: %s\n' "$*" >&2; }
die() {
  local code="$1"
  shift
  printf '[git-commit] 오류: %s\n' "$*" >&2
  exit "$code"
}

usage() {
  cat <<'EOF'
사용법: commit.sh <type> <제목...> [옵션]

type:
  feat | fix | refactor | chore | docs | test

옵션:
  --body <내용>       본문에 한 줄을 추가한다 (여러 번 지정 가능)
  --issue <번호>      'Refs: #<번호>' 푸터를 추가한다 (기본: 브랜치명의 이슈 번호)
  --no-issue          이슈 번호 푸터를 추가하지 않는다
  --allow-protected   main, master, develop, dev, development에 직접 커밋한다 (사용자 승인 필요)
  --allow-sensitive   민감한 파일로 의심되는 파일이 있어도 커밋한다 (사용자 승인 필요)
  --dry-run           검증과 메시지 미리보기만 수행하고 커밋하지 않는다
  -h, --help          도움말을 출력한다
EOF
}

# UTF-8 연속 바이트(0x80-0xBF)를 빼고 바이트 수를 세서 글자 수를 구한다. 로케일 설정과 관계없이 동작한다.
char_count() {
  printf '%s' "$1" | LC_ALL=C tr -d '\200-\277' | wc -c | tr -d ' '
}

is_sensitive_file() {
  local name
  name="$(printf '%s' "${1##*/}" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
  case "$name" in
    *.example|*.sample|*.template|*.pub) return 1 ;;
    .env|.env.*|*.pem|*.key|*.p12|*.pfx|*.jks|*.keystore|*.tfvars|*.secret) return 0 ;;
    id_rsa*|id_dsa*|id_ecdsa*|id_ed25519*|credentials|credentials.*|secrets.*|.netrc|.pypirc) return 0 ;;
  esac
  return 1
}

# ---------------------------------------------------------------------------
# 인자 해석
# ---------------------------------------------------------------------------

type=""
subject=""
body=""
issue=""
no_issue=false
allow_protected=false
allow_sensitive=false
dry_run=false

need_value() {
  [ "$2" -ge 2 ] || die 2 "옵션에 값이 필요합니다: $1"
}

# 첫 번째 위치 인자는 type, 나머지는 공백으로 이어 붙여 제목으로 사용한다.
add_positional() {
  if [ -z "$type" ]; then
    type="$1"
  else
    subject="${subject:+$subject }$1"
  fi
}

add_body_line() {
  if [ -z "$body" ]; then
    body="$1"
  else
    body="$body"$'\n'"$1"
  fi
}

while [ $# -gt 0 ]; do
  case "$1" in
    --body)            need_value "$1" $#; add_body_line "$2"; shift 2 ;;
    --body=*)          add_body_line "${1#*=}"; shift ;;
    --issue)           need_value "$1" $#; issue="$2"; shift 2 ;;
    --issue=*)         issue="${1#*=}"; shift ;;
    --no-issue)        no_issue=true; shift ;;
    --allow-protected) allow_protected=true; shift ;;
    --allow-sensitive) allow_sensitive=true; shift ;;
    --dry-run)         dry_run=true; shift ;;
    -h|--help)         usage; exit 0 ;;
    --)                shift; while [ $# -gt 0 ]; do add_positional "$1"; shift; done ;;
    -*)                die 2 "알 수 없는 옵션입니다: $1" ;;
    *)                 add_positional "$1"; shift ;;
  esac
done

# ---------------------------------------------------------------------------
# 커밋 메시지 조합과 검증 (저장소에 접근하지 않는 검사)
# ---------------------------------------------------------------------------

[ -n "$type" ] || { usage >&2; die 2 "type을 입력해야 합니다."; }

type="$(printf '%s' "${type%:}" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
[[ "$type" =~ ^[a-z]+$ ]] || die 2 "허용되지 않는 type입니다: '$type' (허용: $ALLOWED_TYPES)"
case " $ALLOWED_TYPES " in
  *" $type "*) ;;
  *) die 2 "허용되지 않는 type입니다: '$type' (허용: $ALLOWED_TYPES)" ;;
esac

subject="$(printf '%s' "$subject" | LC_ALL=C sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
[ -n "$subject" ] || die 2 "커밋 제목을 입력해야 합니다."

if [[ "$subject" == *$'\n'* || "$subject" == *$'\r'* ]]; then
  die 2 "제목은 한 줄로 작성해야 합니다. 자세한 내용은 --body 옵션으로 전달하세요."
fi

lower_subject="$(printf '%s' "$subject" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
for allowed in $ALLOWED_TYPES; do
  case "$lower_subject" in
    "$allowed":*|"$allowed("*) die 2 "제목에는 type을 빼고 전달하세요: '$subject'" ;;
  esac
done

case "$subject" in
  *.|*。) die 2 "제목 끝에 마침표를 찍지 않습니다: '$subject'" ;;
esac

header="$type: $subject"
header_length="$(char_count "$header")"
if [ "$header_length" -gt "$MAX_HEADER_LENGTH" ]; then
  die 3 "제목 줄이 ${header_length}자로 ${MAX_HEADER_LENGTH}자를 넘습니다. 제목을 줄이고 자세한 내용은 --body 옵션으로 옮기세요: '$header'"
fi

if [ -n "$issue" ]; then
  [ "$no_issue" = false ] || die 2 "--issue와 --no-issue 옵션은 함께 사용할 수 없습니다."
  issue="${issue#\#}"
  [[ "$issue" =~ ^[0-9]+$ ]] || die 2 "이슈 번호는 숫자만 입력할 수 있습니다: '$issue'"
fi

# ---------------------------------------------------------------------------
# 저장소와 브랜치 상태 확인
# ---------------------------------------------------------------------------

[ "$(git rev-parse --is-inside-work-tree 2>/dev/null || true)" = true ] \
  || die 1 "Git 저장소의 작업 트리 안에서 실행해야 합니다."

for state in rebase-merge rebase-apply MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD; do
  if [ -e "$(git rev-parse --git-path "$state")" ]; then
    die 1 "진행 중인 Git 작업이 있습니다. 해당 작업을 먼저 완료하거나 중단한 뒤 다시 실행하세요: $state"
  fi
done

branch="$(git symbolic-ref --quiet --short HEAD || true)"
[ -n "$branch" ] || die 1 "HEAD가 브랜치를 가리키지 않는 상태(detached HEAD)입니다. 작업 브랜치로 전환한 뒤 다시 실행하세요."

case " $PROTECTED_BRANCHES " in
  *" $branch "*)
    [ "$allow_protected" = true ] \
      || die 4 "보호 브랜치에 직접 커밋하려고 합니다: '$branch'. 작업 브랜치를 만들지 사용자에게 확인하고, 직접 커밋하려면 --allow-protected 옵션을 추가하세요."
    warn "--allow-protected 옵션에 따라 보호 브랜치에 직접 커밋합니다: '$branch'"
    ;;
esac

issue_pattern='^[a-z]+/([0-9]+)-'
if [ -z "$issue" ] && [ "$no_issue" = false ] && [[ "$branch" =~ $issue_pattern ]]; then
  issue="${BASH_REMATCH[1]}"
  log "브랜치명에 있는 이슈 번호를 푸터에 추가합니다: #$issue"
fi

# ---------------------------------------------------------------------------
# 스테이징 상태 확인
# ---------------------------------------------------------------------------

staged_files="$(git -c core.quotePath=false diff --cached --name-only)"
[ -n "$staged_files" ] \
  || die 5 "스테이징한 변경 사항이 없습니다. 커밋할 파일을 git add <파일 경로>로 스테이징한 뒤 다시 실행하세요."
file_count="$(printf '%s\n' "$staged_files" | wc -l | tr -d ' ')"

# 삭제한 파일은 저장소에서 민감 정보를 없애는 변경이므로 검사하지 않는다.
sensitive_files=""
while IFS= read -r file; do
  if [ -n "$file" ] && is_sensitive_file "$file"; then
    sensitive_files="$sensitive_files$file"$'\n'
  fi
done <<< "$(git -c core.quotePath=false diff --cached --name-only --diff-filter=d)"

if [ -n "$sensitive_files" ]; then
  if [ "$allow_sensitive" = false ]; then
    log "민감한 파일로 의심되는 스테이징 파일:"
    printf '%s' "$sensitive_files" >&2
    die 6 "민감한 파일로 의심되는 파일이 스테이징되어 있습니다. 사용자에게 확인하고, 커밋에서 빼려면 git restore --staged <파일 경로>를 실행하세요."
  fi
  warn "--allow-sensitive 옵션에 따라 민감한 파일로 의심되는 파일을 함께 커밋합니다."
fi

unstaged_count="$(git status --porcelain --untracked-files=normal | grep -c '^.[^ ]' || true)"
if [ "$unstaged_count" -gt 0 ]; then
  warn "스테이징하지 않은 변경 사항이 ${unstaged_count}개 있으며, 이번 커밋에는 포함되지 않습니다."
fi

# ---------------------------------------------------------------------------
# 커밋
# ---------------------------------------------------------------------------

message="$header"
if [ -n "$body" ]; then
  message="$message"$'\n\n'"$body"
fi
if [ -n "$issue" ]; then
  message="$message"$'\n\n'"Refs: #$issue"
fi
message="$(printf '%s' "$message" | tr -d '\r')"

print_result() {
  printf 'RESULT=%s\n' "$1"
  printf 'COMMIT=%s\n' "$2"
  printf 'BRANCH=%s\n' "$branch"
  printf 'HEADER=%s\n' "$header"
  printf 'FILES=%s\n' "$file_count"
}

log "커밋 메시지:"
printf '%s\n' "$message" | LC_ALL=C sed 's/^/    /' >&2

if [ "$dry_run" = true ]; then
  log "--dry-run 옵션에 따라 커밋하지 않습니다."
  print_result dry-run ""
  exit 0
fi

# 본문에서 '#'으로 시작하는 줄(예: #128)이 주석으로 지워지지 않도록 cleanup 모드를 whitespace로 지정한다.
if ! commit_output="$(printf '%s\n' "$message" | git commit --quiet --cleanup=whitespace -F - 2>&1)"; then
  die 1 "커밋하지 못했습니다. 훅이 실패했다면 원인을 수정한 뒤 다시 실행하고, --no-verify로 우회하지 마세요.
$commit_output"
fi

print_result committed "$(git rev-parse --short HEAD)"
