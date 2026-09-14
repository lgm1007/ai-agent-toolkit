#!/usr/bin/env bash
#
# git-push 스킬 규칙에 따라 현재 브랜치를 같은 이름의 원격 브랜치로 push하고, push 후 상태를 확인한다.
#
# 원격 브랜치 조회, 사전 검증, push, upstream 설정, 원격 커밋 확인을 이 스크립트가 일괄 처리하므로
# 어떤 에이전트가 실행하더라도 같은 절차와 결과를 얻는다.
#
# 사용법:
#   push.sh [--remote <이름>] [--allow-protected] [--allow-sensitive] [--dry-run]
#
# 결과 (표준 출력, key=value 형식):
#   RESULT=pushed | up-to-date | dry-run
#   BRANCH=<현재 브랜치>
#   REMOTE=<원격 저장소>
#   UPSTREAM=<push 후 설정되는 upstream>
#   COMMITS=<원격 브랜치에 새로 올라가는 커밋 수>
#   NEW_BRANCH=true | false
#   HEAD_COMMIT=<로컬 HEAD 커밋>
#   PR_URL=<원격 저장소가 안내한 PR 생성 링크, 없으면 빈 값>
#
# 종료 코드:
#   0  성공
#   1  저장소 상태 오류 또는 git 명령 실패
#   2  인자 오류
#   3  보호 브랜치에 직접 push
#   4  원격 저장소 없음
#   5  원격 브랜치에 로컬에 없는 커밋 존재
#   6  민감한 파일로 의심되는 파일 포함
#   7  원격 조회 또는 push 실패
#   8  push 후 상태 검증 실패
#
# 요구 사항: bash 3.2 이상, git 2.23 이상

set -euo pipefail

readonly PROTECTED_BRANCHES="main master develop dev development"

# 인증 정보가 없을 때 입력 대기로 멈추지 않고 바로 실패하도록 한다.
export GIT_TERMINAL_PROMPT=0

log()  { printf '[git-push] %s\n' "$*" >&2; }
warn() { printf '[git-push] 경고: %s\n' "$*" >&2; }
die() {
  local code="$1"
  shift
  printf '[git-push] 오류: %s\n' "$*" >&2
  exit "$code"
}

usage() {
  cat <<'EOF'
사용법: push.sh [옵션]

현재 브랜치를 같은 이름의 원격 브랜치로 push하고 상태를 확인한다.

옵션:
  --remote <이름>      원격 저장소 이름 (기본: upstream의 원격 저장소, 없으면 origin)
  --allow-protected    main, master, develop, dev, development 브랜치의 직접 push를 허용한다 (사용자 승인 필요)
  --allow-sensitive    민감한 파일로 의심되는 파일이 있어도 push한다 (사용자 승인 필요)
  --dry-run            검증과 push 대상 확인까지만 수행하고 push하지 않는다
  -h, --help           도움말을 출력한다
EOF
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

remote=""
allow_protected=false
allow_sensitive=false
dry_run=false

need_value() {
  [ "$2" -ge 2 ] || die 2 "옵션에 값이 필요합니다: $1"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --remote)          need_value "$1" $#; remote="$2"; shift 2 ;;
    --allow-protected) allow_protected=true; shift ;;
    --allow-sensitive) allow_sensitive=true; shift ;;
    --dry-run)         dry_run=true; shift ;;
    -h|--help)         usage; exit 0 ;;
    *)                 die 2 "알 수 없는 인자입니다: $1 (이 스크립트는 현재 브랜치만 push합니다)" ;;
  esac
done

# ---------------------------------------------------------------------------
# 저장소와 브랜치 상태 확인
# ---------------------------------------------------------------------------

[ "$(git rev-parse --is-inside-work-tree 2>/dev/null || true)" = true ] \
  || die 1 "Git 저장소의 작업 트리 안에서 실행해야 합니다."

for state in rebase-merge rebase-apply MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD BISECT_LOG; do
  if [ -e "$(git rev-parse --git-path "$state")" ]; then
    die 1 "진행 중인 Git 작업이 있습니다. 해당 작업을 완료하거나 중단한 뒤 다시 실행하세요: $state"
  fi
done

branch="$(git symbolic-ref --quiet --short HEAD || true)"
[ -n "$branch" ] || die 1 "HEAD가 브랜치를 가리키지 않는 상태(detached HEAD)입니다. push할 브랜치로 전환한 뒤 다시 실행하세요."

head_commit="$(git rev-parse --verify --quiet HEAD || true)"
[ -n "$head_commit" ] || die 1 "커밋이 없는 브랜치는 push할 수 없습니다: '$branch'"

case " $PROTECTED_BRANCHES " in
  *" $branch "*)
    [ "$allow_protected" = true ] \
      || die 3 "보호 브랜치에 직접 push하려고 합니다: '$branch'. 사용자에게 확인하고, 직접 push하려면 --allow-protected 옵션을 추가하세요."
    warn "--allow-protected 옵션에 따라 보호 브랜치에 직접 push합니다: '$branch'"
    ;;
esac

# ---------------------------------------------------------------------------
# 원격 저장소와 upstream 결정
# ---------------------------------------------------------------------------

upstream_remote="$(git config --get "branch.$branch.remote" || true)"
upstream_merge="$(git config --get "branch.$branch.merge" || true)"

if [ -z "$remote" ]; then
  if [ -n "$upstream_remote" ] && [ "$upstream_remote" != . ]; then
    remote="$upstream_remote"
  else
    remote=origin
  fi
fi
grep -Fxq -- "$remote" <<< "$(git remote)" || die 4 "원격 저장소를 찾을 수 없습니다: '$remote'"

upstream="$remote/$branch"
remote_ref="refs/remotes/$remote/$branch"
current_upstream=""
if [ -n "$upstream_merge" ]; then
  current_upstream="$upstream_remote/${upstream_merge#refs/heads/}"
fi
if [ -n "$current_upstream" ] && [ "$current_upstream" != "$upstream" ]; then
  warn "현재 upstream이 브랜치 이름과 다릅니다. push 후 upstream을 변경합니다: $current_upstream -> $upstream"
fi

set_upstream() {
  git config "branch.$branch.remote" "$remote"
  git config "branch.$branch.merge" "refs/heads/$branch"
}

# ---------------------------------------------------------------------------
# 원격 브랜치 상태 확인
# ---------------------------------------------------------------------------

log "원격 브랜치 상태를 조회합니다: $upstream"
if ! ls_remote_output="$(git ls-remote --heads "$remote" "refs/heads/$branch" 2>&1)"; then
  die 7 "원격 저장소 조회에 실패했습니다. 네트워크와 인증 상태를 확인하세요: $remote
$ls_remote_output"
fi
remote_commit="$(awk -v ref="refs/heads/$branch" '$2 == ref { print $1 }' <<< "$ls_remote_output")"

if [ -n "$remote_commit" ]; then
  new_branch=false
  # 단일 브랜치 clone처럼 fetch refspec이 제한된 저장소에서도 동작하도록 refspec을 명시한다.
  if ! fetch_output="$(git fetch --quiet "$remote" "+refs/heads/$branch:$remote_ref" 2>&1)"; then
    die 7 "원격 브랜치를 fetch하지 못했습니다: $upstream
$fetch_output"
  fi
  behind="$(git rev-list --count "HEAD..$remote_ref")"
  ahead="$(git rev-list --count "$remote_ref..HEAD")"
  if [ "$behind" -gt 0 ]; then
    die 5 "원격 브랜치에 로컬에 없는 커밋이 ${behind}개 있습니다(로컬에만 있는 커밋 ${ahead}개). 원격 변경 사항을 merge와 rebase 중 어떤 방식으로 가져올지 사용자에게 확인하세요. 강제 push는 하지 않습니다: $upstream"
  fi
  range=("$remote_ref..HEAD")
else
  new_branch=true
  # 원격 저장소의 다른 브랜치에 이미 있는 커밋은 빼고 센다.
  range=(HEAD --not "--remotes=$remote")
  ahead="$(git rev-list --count "${range[@]}")"
fi

print_result() {
  printf 'RESULT=%s\n' "$1"
  printf 'BRANCH=%s\n' "$branch"
  printf 'REMOTE=%s\n' "$remote"
  printf 'UPSTREAM=%s\n' "$upstream"
  printf 'COMMITS=%s\n' "$ahead"
  printf 'NEW_BRANCH=%s\n' "$new_branch"
  printf 'HEAD_COMMIT=%s\n' "$(git rev-parse --short HEAD)"
  printf 'PR_URL=%s\n' "$2"
}

if [ "$new_branch" = false ] && [ "$ahead" -eq 0 ]; then
  if [ "$dry_run" = false ] && [ "$current_upstream" != "$upstream" ]; then
    set_upstream
    log "upstream을 설정했습니다: $upstream"
  fi
  log "원격 브랜치가 이미 최신 상태입니다: $upstream"
  print_result up-to-date ""
  exit 0
fi

# ---------------------------------------------------------------------------
# push할 커밋 확인
# ---------------------------------------------------------------------------

if [ "$ahead" -gt 0 ]; then
  log "push할 커밋 (${ahead}개):"
  git log --oneline --no-decorate --max-count=20 "${range[@]}" | LC_ALL=C sed 's/^/    /' >&2
  if [ "$ahead" -gt 20 ]; then
    printf '    ... 외 %d개\n' "$((ahead - 20))" >&2
  fi

  # 나중 커밋에서 삭제한 파일도 push하면 이력에 남으므로, 추가하거나 수정한 파일을 모두 검사한다.
  sensitive_files=""
  while IFS= read -r file; do
    if [ -n "$file" ] && is_sensitive_file "$file"; then
      sensitive_files="$sensitive_files    $file"$'\n'
    fi
  done <<< "$(git -c core.quotePath=false log --format= --name-only --diff-filter=AM "${range[@]}" | LC_ALL=C sort -u)"

  if [ -n "$sensitive_files" ]; then
    if [ "$allow_sensitive" = false ]; then
      log "민감한 파일로 의심되는 파일:"
      printf '%s' "$sensitive_files" >&2
      die 6 "push할 커밋에 민감한 파일로 의심되는 파일이 있습니다. 사용자에게 확인하고, 그대로 push하려면 --allow-sensitive 옵션을 추가하세요."
    fi
    warn "--allow-sensitive 옵션에 따라 민감한 파일로 의심되는 파일이 포함된 커밋을 push합니다."
  fi
fi

changes_count="$(git status --porcelain --untracked-files=normal | wc -l | tr -d ' ')"
if [ "$changes_count" -gt 0 ]; then
  warn "커밋되지 않은 변경 사항 ${changes_count}개는 push에 포함되지 않습니다."
fi

if [ "$dry_run" = true ]; then
  log "--dry-run 옵션에 따라 push하지 않습니다."
  print_result dry-run ""
  exit 0
fi

# ---------------------------------------------------------------------------
# push와 상태 확인
# ---------------------------------------------------------------------------

log "push합니다: $branch -> $upstream"
if ! push_output="$(git push "$remote" "refs/heads/$branch:refs/heads/$branch" 2>&1)"; then
  die 7 "push에 실패했습니다. pre-push 훅 결과와 원격 저장소의 권한, 브랜치 보호 규칙을 확인하세요.
$push_output"
fi

set_upstream

if ! verify_output="$(git ls-remote --heads "$remote" "refs/heads/$branch" 2>&1)"; then
  die 8 "push 후 원격 브랜치를 조회하지 못했습니다.
$verify_output"
fi
pushed_commit="$(awk -v ref="refs/heads/$branch" '$2 == ref { print $1 }' <<< "$verify_output")"
if [ "$pushed_commit" != "$head_commit" ]; then
  die 8 "push 후 원격 브랜치가 로컬 HEAD와 다른 커밋을 가리킵니다. (원격: ${pushed_commit:-없음}, 로컬: $head_commit)"
fi

# fetch refspec이 제한된 저장소에서도 원격 추적 브랜치가 push 결과를 가리키도록 갱신한다.
git update-ref "$remote_ref" "$head_commit"

pr_url="$(printf '%s\n' "$push_output" \
  | grep -Eo 'https?://[^[:space:]]+/(pull/new|merge_requests/new|pull-requests/new)[^[:space:]]*' \
  | head -n 1 || true)"

status_output="$(git status --short --branch --untracked-files=no)"
log "브랜치 상태: ${status_output%%$'\n'*}"
log "push와 상태 확인을 완료했습니다: $upstream ($(git rev-parse --short HEAD))"
print_result pushed "$pr_url"
