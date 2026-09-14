#!/usr/bin/env bash
#
# git-merge-to-target 스킬 규칙에 따라 source 브랜치를 target 브랜치에 merge하고, target 브랜치를 원격 저장소에 push한다.
#
# 브랜치 상태 검증, 충돌 사전 검사, merge, push, 실패 시 복구를 이 스크립트가 일괄 처리하므로
# 어떤 에이전트가 실행하더라도 같은 절차로 병합된다.
#
# 사용법:
#   merge-to-target.sh <target_branch> [source_branch] [옵션]
#
# 예시:
#   merge-to-target.sh develop --dry-run
#   merge-to-target.sh develop feat/128-add-kakao-social-login
#
# 결과 (표준 출력, key=value 형식):
#   RESULT=merged | up-to-date | dry-run
#   SOURCE=<source 브랜치>
#   TARGET=<target 브랜치>
#   REMOTE=<원격 저장소>
#   COMMITS=<target 브랜치에 새로 반영되는 커밋 수>
#   MERGE_COMMIT=<merge 커밋 해시, merged가 아니면 빈 값>
#
# 종료 코드:
#   0  성공
#   1  저장소 상태 오류 또는 git 명령 실패
#   2  인자 오류
#   3  커밋되지 않은 변경 사항 존재
#   4  브랜치 또는 원격 저장소 없음
#   5  로컬과 원격 브랜치 상태 불일치
#   6  merge 충돌 예상
#   7  fetch 또는 push 실패
#
# 요구 사항: bash 3.2 이상, git 2.23 이상 (충돌 사전 검사는 git 2.38 이상)

set -euo pipefail

readonly PROTECTED_TARGETS="main master"

# 인증 정보가 없을 때 입력 대기로 멈추지 않고 바로 실패하도록 한다.
export GIT_TERMINAL_PROMPT=0

log()  { printf '[git-merge-to-target] %s\n' "$*" >&2; }
warn() { printf '[git-merge-to-target] 경고: %s\n' "$*" >&2; }
die() {
  local code="$1"
  shift
  printf '[git-merge-to-target] 오류: %s\n' "$*" >&2
  exit "$code"
}

usage() {
  cat <<'EOF'
사용법: merge-to-target.sh <target_branch> [source_branch] [옵션]

인자:
  target_branch       merge 결과를 반영하고 push할 브랜치 (예: develop)
  source_branch       merge할 커밋이 있는 브랜치 (기본: 현재 브랜치)

옵션:
  --remote <이름>     원격 저장소 이름 (기본: origin)
  --allow-main        main/master를 target 브랜치로 허용한다 (사용자 승인 필요)
  --dry-run           fetch, 검증, 충돌 사전 검사까지만 수행하고 merge와 push는 하지 않는다
  -h, --help          도움말을 출력한다
EOF
}

# ---------------------------------------------------------------------------
# 인자 해석
# ---------------------------------------------------------------------------

target_branch=""
source_branch=""
remote="origin"
allow_main=false
dry_run=false
positional_count=0

need_value() {
  [ "$2" -ge 2 ] || die 2 "옵션에 값이 필요합니다: $1"
}

add_positional() {
  positional_count=$((positional_count + 1))
  case "$positional_count" in
    1) target_branch="$1" ;;
    2) source_branch="$1" ;;
    *) die 2 "인자가 너무 많습니다: '$1' (사용법: merge-to-target.sh <target_branch> [source_branch])" ;;
  esac
}

while [ $# -gt 0 ]; do
  case "$1" in
    --remote)     need_value "$1" $#; remote="$2"; shift 2 ;;
    --allow-main) allow_main=true; shift ;;
    --dry-run)    dry_run=true; shift ;;
    -h|--help)    usage; exit 0 ;;
    --)           shift; while [ $# -gt 0 ]; do add_positional "$1"; shift; done ;;
    -*)           die 2 "알 수 없는 옵션입니다: $1" ;;
    *)            add_positional "$1"; shift ;;
  esac
done

# refs/heads/develop, origin/develop처럼 전달해도 브랜치 이름만 사용한다.
normalize_branch() {
  local name="$1"
  name="${name#refs/heads/}"
  name="${name#refs/remotes/"$remote"/}"
  name="${name#"$remote"/}"
  printf '%s' "$name"
}

validate_branch_name() {
  case "$2" in
    ""|-*) die 2 "브랜치 이름이 올바르지 않습니다 ($1): '$2'" ;;
  esac
  git check-ref-format "refs/heads/$2" || die 2 "브랜치 이름이 올바르지 않습니다 ($1): '$2'"
}

[ -n "$target_branch" ] || { usage >&2; die 2 "target_branch를 입력해야 합니다."; }

target_branch="$(normalize_branch "$target_branch")"
validate_branch_name target_branch "$target_branch"

case " $PROTECTED_TARGETS " in
  *" $target_branch "*)
    [ "$allow_main" = true ] \
      || die 2 "main/master 브랜치에는 직접 merge하지 않는 것이 원칙입니다. 사용자가 명시적으로 요청한 경우에만 --allow-main 옵션을 추가하세요: '$target_branch'"
    warn "--allow-main 옵션에 따라 '$target_branch' 브랜치에 직접 merge합니다."
    ;;
esac

# ---------------------------------------------------------------------------
# 저장소 상태 확인
# ---------------------------------------------------------------------------

[ "$(git rev-parse --is-inside-work-tree 2>/dev/null || true)" = true ] \
  || die 1 "Git 저장소의 작업 트리 안에서 실행해야 합니다."

for state in rebase-merge rebase-apply MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD BISECT_LOG; do
  if [ -e "$(git rev-parse --git-path "$state")" ]; then
    die 1 "진행 중인 Git 작업이 있습니다. 해당 작업을 완료하거나 중단한 뒤 다시 실행하세요: $state"
  fi
done

original_branch="$(git symbolic-ref --quiet --short HEAD || true)"
original_head="$(git rev-parse --verify --quiet HEAD || true)"
[ -n "$original_head" ] || die 1 "커밋이 없는 저장소에서는 merge할 수 없습니다."

if [ -z "$source_branch" ]; then
  [ -n "$original_branch" ] || die 2 "detached HEAD 상태에서는 source_branch를 지정해야 합니다."
  source_branch="$original_branch"
else
  source_branch="$(normalize_branch "$source_branch")"
fi
validate_branch_name source_branch "$source_branch"
[ "$source_branch" != "$target_branch" ] || die 2 "source_branch와 target_branch가 같습니다: '$target_branch'"

if ! grep -Fxq -- "$remote" <<< "$(git remote)"; then
  die 4 "원격 저장소를 찾을 수 없습니다: '$remote'"
fi

changes="$(git status --porcelain --untracked-files=no)"
if [ -n "$changes" ]; then
  log "커밋되지 않은 변경 사항:"
  printf '%s\n' "$changes" >&2
  die 3 "커밋되지 않은 변경 사항이 있습니다. 커밋하거나 stash할지 사용자에게 확인한 뒤 다시 실행하세요."
fi

# ---------------------------------------------------------------------------
# 원격 브랜치 확인과 fetch
# ---------------------------------------------------------------------------

log "원격 브랜치 정보를 조회합니다: $remote"
if ! ls_remote_output="$(git ls-remote --heads "$remote" "refs/heads/$target_branch" "refs/heads/$source_branch" 2>&1)"; then
  die 7 "원격 저장소 조회에 실패했습니다. 네트워크와 인증 상태를 확인하세요: $remote
$ls_remote_output"
fi
remote_branches="$(sed -n 's#^[0-9a-f]*[[:space:]]*refs/heads/##p' <<< "$ls_remote_output")"

remote_has_branch() {
  [ -n "$remote_branches" ] && grep -Fxq -- "$1" <<< "$remote_branches"
}

local_has_branch() {
  git show-ref --verify --quiet "refs/heads/$1"
}

remote_has_branch "$target_branch" \
  || die 4 "원격 저장소에 target 브랜치가 없습니다. 브랜치 이름을 확인하세요: '$remote/$target_branch'"

remote_target_ref="refs/remotes/$remote/$target_branch"
remote_source_ref="refs/remotes/$remote/$source_branch"

# 단일 브랜치 clone처럼 fetch refspec이 제한된 저장소에서도 동작하도록 refspec을 명시한다.
fetch_refspecs=("+refs/heads/$target_branch:$remote_target_ref")
if remote_has_branch "$source_branch"; then
  fetch_refspecs+=("+refs/heads/$source_branch:$remote_source_ref")
fi

log "원격 브랜치의 최신 상태를 가져옵니다."
if ! fetch_output="$(git fetch --quiet "$remote" "${fetch_refspecs[@]}" 2>&1)"; then
  die 7 "원격 브랜치를 fetch하지 못했습니다.
$fetch_output"
fi

# ---------------------------------------------------------------------------
# 로컬과 원격 브랜치 상태 확인
# ---------------------------------------------------------------------------

if local_has_branch "$source_branch"; then
  source_ref="refs/heads/$source_branch"
  if remote_has_branch "$source_branch"; then
    behind="$(git rev-list --count "$source_ref..$remote_source_ref")"
    if [ "$behind" -gt 0 ]; then
      die 5 "원격 source 브랜치에 로컬에 없는 커밋이 ${behind}개 있습니다. source 브랜치를 pull할지 사용자에게 확인하세요: '$remote/$source_branch'"
    fi
  fi
elif remote_has_branch "$source_branch"; then
  source_ref="$remote_source_ref"
  log "로컬에 source 브랜치가 없어 원격 브랜치를 사용합니다: $remote/$source_branch"
else
  die 4 "source 브랜치를 로컬과 원격 저장소에서 찾을 수 없습니다: '$source_branch'"
fi

local_target_exists=false
if local_has_branch "$target_branch"; then
  local_target_exists=true
  unpushed="$(git rev-list --count "$remote_target_ref..refs/heads/$target_branch")"
  if [ "$unpushed" -gt 0 ]; then
    die 5 "로컬 target 브랜치에 원격 저장소에 없는 커밋이 ${unpushed}개 있습니다. 이 커밋을 어떻게 처리할지 사용자에게 확인하세요: '$target_branch'"
  fi
fi

current_worktree="$(git rev-parse --show-toplevel)"
worktree_path=""
while IFS= read -r line; do
  case "$line" in
    "worktree "*)
      worktree_path="${line#worktree }"
      ;;
    "branch refs/heads/$target_branch")
      if [ "$worktree_path" != "$current_worktree" ]; then
        die 1 "target 브랜치가 다른 worktree에 체크아웃되어 있습니다: $worktree_path"
      fi
      ;;
  esac
done <<< "$(git worktree list --porcelain)"

# ---------------------------------------------------------------------------
# merge 대상 커밋 확인과 충돌 사전 검사
# ---------------------------------------------------------------------------

commit_count="$(git rev-list --count "$remote_target_ref..$source_ref")"

print_result() {
  printf 'RESULT=%s\n' "$1"
  printf 'SOURCE=%s\n' "$source_branch"
  printf 'TARGET=%s\n' "$target_branch"
  printf 'REMOTE=%s\n' "$remote"
  printf 'COMMITS=%s\n' "$commit_count"
  printf 'MERGE_COMMIT=%s\n' "$2"
}

if [ "$commit_count" -eq 0 ]; then
  log "source 브랜치의 커밋이 이미 target 브랜치에 모두 반영되어 있습니다."
  print_result up-to-date ""
  exit 0
fi

log "target 브랜치에 반영될 커밋 (${commit_count}개):"
git log --oneline --no-decorate --max-count=20 "$remote_target_ref..$source_ref" | LC_ALL=C sed 's/^/    /' >&2
if [ "$commit_count" -gt 20 ]; then
  printf '    ... 외 %d개\n' "$((commit_count - 20))" >&2
fi

merge_tree_status=0
merge_tree_output="$(git merge-tree --write-tree --name-only --no-messages "$remote_target_ref" "$source_ref" 2>&1)" \
  || merge_tree_status=$?

case "$merge_tree_status" in
  0) ;;
  1)
    log "충돌이 예상되는 파일:"
    printf '%s\n' "$merge_tree_output" | LC_ALL=C sed '1d; /^$/d; s/^/    /' >&2
    die 6 "merge 충돌이 예상되어 작업 트리를 변경하지 않고 중단합니다. source 브랜치에 target 브랜치를 먼저 merge해 충돌을 해결한 뒤 다시 실행하세요."
    ;;
  *)
    warn "이 git 버전에서는 충돌 사전 검사를 할 수 없어 건너뜁니다. (git 2.38 이상 필요)"
    ;;
esac

if [ "$dry_run" = true ]; then
  log "--dry-run 옵션에 따라 merge와 push를 수행하지 않습니다."
  print_result dry-run ""
  exit 0
fi

# ---------------------------------------------------------------------------
# merge와 push
# ---------------------------------------------------------------------------

return_to_original() {
  if [ -n "$original_branch" ]; then
    git switch --quiet "$original_branch"
  else
    git switch --quiet --detach "$original_head"
  fi
}

log "target 브랜치로 전환합니다: $target_branch"
if [ "$local_target_exists" = true ]; then
  if ! switch_output="$(git switch --quiet "$target_branch" 2>&1)"; then
    die 1 "target 브랜치로 전환하지 못했습니다.
$switch_output"
  fi
  if ! ff_output="$(git merge --quiet --ff-only "$remote_target_ref" 2>&1)"; then
    return_to_original >/dev/null 2>&1 || warn "원래 브랜치로 돌아가지 못했습니다: ${original_branch:-$original_head}"
    die 1 "target 브랜치를 원격 상태로 맞추지 못했습니다.
$ff_output"
  fi
else
  if ! switch_output="$(git switch --quiet --track -c "$target_branch" "$remote_target_ref" 2>&1)"; then
    die 1 "target 브랜치를 만들지 못했습니다.
$switch_output"
  fi
fi
target_before="$(git rev-parse HEAD)"

# 같은 이름의 태그와 헷갈리지 않도록 merge 대상은 전체 ref 이름으로 지정하고,
# 커밋 메시지에는 Git 기본 형식과 같은 짧은 브랜치 이름을 사용한다.
if [ "$source_ref" = "$remote_source_ref" ]; then
  merge_message="Merge remote-tracking branch '$remote/$source_branch' into $target_branch"
else
  merge_message="Merge branch '$source_branch' into $target_branch"
fi

log "merge합니다: $source_branch -> $target_branch"
if ! merge_output="$(git merge --no-ff --no-edit -m "$merge_message" "$source_ref" 2>&1)"; then
  conflicted="$(git diff --name-only --diff-filter=U 2>/dev/null || true)"
  git merge --abort >/dev/null 2>&1 || true
  return_to_original >/dev/null 2>&1 || warn "원래 브랜치로 돌아가지 못했습니다: ${original_branch:-$original_head}"
  if [ -n "$conflicted" ]; then
    log "충돌이 발생한 파일:"
    printf '%s\n' "$conflicted" | LC_ALL=C sed 's/^/    /' >&2
    die 6 "merge 충돌이 발생해 merge를 중단하고 원래 상태로 되돌렸습니다. source 브랜치에 target 브랜치를 먼저 merge해 충돌을 해결한 뒤 다시 실행하세요."
  fi
  die 1 "merge에 실패해 원래 상태로 되돌렸습니다.
$merge_output"
fi
merge_commit="$(git rev-parse --short HEAD)"

log "원격 저장소에 push합니다: $remote/$target_branch"
if ! push_output="$(git push --quiet "$remote" "refs/heads/$target_branch:refs/heads/$target_branch" 2>&1)"; then
  # 원격에 반영되지 않은 merge 커밋이 로컬에 남지 않도록, 방금 만든 merge 커밋만 되돌린다.
  # merge 전에 커밋되지 않은 변경 사항이 없음을 확인했으므로 되돌려도 사용자 작업은 사라지지 않는다.
  git reset --quiet --hard "$target_before" || warn "로컬 target 브랜치를 merge 이전 상태로 되돌리지 못했습니다."
  return_to_original >/dev/null 2>&1 || warn "원래 브랜치로 돌아가지 못했습니다: ${original_branch:-$original_head}"
  die 7 "push에 실패해 로컬 target 브랜치를 merge 이전 상태로 되돌렸습니다. 원격 저장소의 브랜치 보호 규칙과 권한을 확인하세요.
$push_output"
fi

if ! return_to_original >/dev/null 2>&1; then
  warn "원래 브랜치로 돌아가지 못했습니다. 현재 브랜치: $target_branch"
fi

log "merge와 push를 완료했습니다: $remote/$target_branch ($merge_commit)"
print_result merged "$merge_commit"
