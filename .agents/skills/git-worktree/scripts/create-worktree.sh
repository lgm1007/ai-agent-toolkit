#!/usr/bin/env bash
#
# git-worktree 스킬 규칙에 따라 개발 브랜치에서 새 작업 브랜치를 만들고,
# 그 브랜치를 체크아웃한 독립 작업 디렉터리(worktree)를 저장소 루트의 .agents/worktree/ 아래에 생성한다.
#
# 브랜치명 조합과 검증, 기준 브랜치 탐색, 중복 확인은 git-branch 스킬의 create-branch.sh를 --dry-run으로 실행해
# 같은 규칙을 그대로 적용한다. 이 스크립트는 worktree 경로 결정, Git 무시 설정, worktree 생성을 담당한다.
#
# 사용법:
#   create-worktree.sh <prefix> <영문 작업명...> [옵션]
#
# 예시:
#   create-worktree.sh feat "add kakao social login"
#   create-worktree.sh fix "order cancel null pointer" --issue 128 --dry-run
#
# 결과 (표준 출력, key=value 형식):
#   RESULT=created | dry-run
#   BRANCH=<브랜치명>
#   BASE=<기준 브랜치>
#   BASE_COMMIT=<기준 커밋>
#   WORKTREE_PATH=<worktree 절대 경로>
#
# 종료 코드 (2, 3, 5, 6, 7은 git-branch 스킬과 같다):
#   0  성공
#   1  저장소 상태 오류 또는 git 명령 실패
#   2  인자 오류
#   3  브랜치명 길이 초과
#   4  worktree 경로가 이미 존재
#   5  기준 브랜치를 찾을 수 없거나 후보가 여러 개
#   6  같은 이름의 브랜치가 이미 존재
#   7  원격 저장소 조회 또는 fetch 실패
#
# 요구 사항: bash 3.2 이상, git 2.23 이상, git-branch 스킬의 scripts/create-branch.sh

set -euo pipefail

readonly WORKTREE_DIR=".agents/worktree"

log()  { printf '[git-worktree] %s\n' "$*" >&2; }
warn() { printf '[git-worktree] 경고: %s\n' "$*" >&2; }
die() {
  local code="$1"
  shift
  printf '[git-worktree] 오류: %s\n' "$*" >&2
  exit "$code"
}

usage() {
  cat <<'EOF'
사용법: create-worktree.sh <prefix> <영문 작업명...> [옵션]

prefix:
  feat | fix | refactor | chore | docs | test

옵션:
  --issue <번호>      이슈 번호를 prefix 뒤에 붙인다 (예: feat/128-add-login)
  --base <브랜치>     기준 브랜치를 지정한다 (기본: develop, dev, development 자동 탐색)
  --remote <이름>     원격 저장소 이름 (기본: origin)
  --no-fetch          원격 저장소에 접속하지 않고 마지막으로 fetch한 정보를 사용한다
  --allow-long        50자를 넘는 브랜치명을 허용한다 (사용자 승인 필요)
  --allow-main-base   main/master를 기준 브랜치로 허용한다 (사용자 승인 필요)
  --dry-run           검증과 경로 확인까지만 수행하고 브랜치와 worktree는 만들지 않는다
  -h, --help          도움말을 출력한다

브랜치명 규칙은 git-branch 스킬과 같으며, worktree는 저장소 루트의
.agents/worktree/<브랜치명의 '/'를 '-'로 바꾼 이름> 경로에 생성한다.
EOF
}

# ---------------------------------------------------------------------------
# 인자 해석: --dry-run과 도움말만 직접 처리하고, 나머지는 git-branch 스크립트에 그대로 전달한다.
# ---------------------------------------------------------------------------

[ $# -gt 0 ] || { usage >&2; die 2 "prefix와 영문 작업명을 입력해야 합니다."; }

dry_run=false
# worktree에는 현재 작업 트리의 변경 사항이 옮겨지지 않으므로, git-branch 스크립트의 변경 사항 검사는 건너뛴다.
branch_args=(--dry-run --allow-dirty)
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)     dry_run=true; shift ;;
    -h|--help)     usage; exit 0 ;;
    --allow-dirty) die 2 "알 수 없는 옵션입니다: $1 (worktree는 현재 작업 트리의 변경 사항을 가져가지 않습니다)" ;;
    --)            branch_args+=("$@"); break ;;
    *)             branch_args+=("$1"); shift ;;
  esac
done

[ "$(git rev-parse --is-inside-work-tree 2>/dev/null || true)" = true ] \
  || die 1 "Git 저장소의 작업 트리 안에서 실행해야 합니다."

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
branch_script="$script_dir/../../git-branch/scripts/create-branch.sh"
[ -f "$branch_script" ] \
  || die 1 "git-branch 스킬의 스크립트를 찾을 수 없습니다. git-branch 스킬이 같은 skills 디렉터리에 있어야 합니다: $branch_script"

# ---------------------------------------------------------------------------
# git-branch 규칙으로 브랜치명과 기준 커밋 결정
# ---------------------------------------------------------------------------

err_file="$(mktemp "${TMPDIR:-/tmp}/git-worktree.XXXXXX")"
trap 'rm -f "$err_file"' EXIT

branch_status=0
branch_output="$(bash "$branch_script" "${branch_args[@]}" 2>"$err_file")" || branch_status=$?

if [ "$branch_status" -ne 0 ]; then
  cat "$err_file" >&2
  exit "$branch_status"
fi

# git-branch 스크립트의 로그 중 worktree 생성과 맞지 않는 안내 문구는 빼고 전달한다.
grep -v -e '--allow-dirty 옵션에 따라' -e '--dry-run 옵션에 따라' "$err_file" >&2 || true

branch="$(sed -n 's/^BRANCH=//p' <<< "$branch_output")"
base_label="$(sed -n 's/^BASE=//p' <<< "$branch_output")"
base_commit="$(sed -n 's/^BASE_COMMIT=//p' <<< "$branch_output")"
if [ -z "$branch" ] || [ -z "$base_commit" ]; then
  die 1 "git-branch 스크립트의 결과를 해석하지 못했습니다.
$branch_output"
fi
base_sha="$(git rev-parse --verify --quiet "$base_commit^{commit}" || true)"
[ -n "$base_sha" ] || die 1 "기준 커밋을 확인하지 못했습니다: $base_commit"

# ---------------------------------------------------------------------------
# worktree 경로 결정
# ---------------------------------------------------------------------------

# 다른 worktree 안에서 실행해도 중첩되지 않도록, 목록의 첫 항목인 메인 작업 트리를 기준으로 한다.
main_worktree="$(git worktree list --porcelain | sed -n '1s/^worktree //p')"
[ -n "$main_worktree" ] && [ -d "$main_worktree" ] || die 1 "메인 작업 트리를 찾을 수 없습니다."

worktree_root="$main_worktree/$WORKTREE_DIR"
worktree_path="$worktree_root/${branch//\//-}"

if [ -e "$worktree_path" ] || [ -L "$worktree_path" ]; then
  die 4 "worktree 경로가 이미 있습니다. 기존 디렉터리를 어떻게 처리할지 사용자에게 확인하세요: $worktree_path"
fi

if [ -n "$(git status --porcelain --untracked-files=normal)" ]; then
  warn "현재 작업 트리의 커밋되지 않은 변경 사항은 새 worktree에 포함되지 않습니다."
fi

print_result() {
  printf 'RESULT=%s\n' "$1"
  printf 'BRANCH=%s\n' "$branch"
  printf 'BASE=%s\n' "$base_label"
  printf 'BASE_COMMIT=%s\n' "$base_commit"
  printf 'WORKTREE_PATH=%s\n' "$worktree_path"
}

if [ "$dry_run" = true ]; then
  log "--dry-run 옵션에 따라 브랜치와 worktree를 만들지 않습니다."
  print_result dry-run
  exit 0
fi

# ---------------------------------------------------------------------------
# Git 무시 설정과 worktree 생성
# ---------------------------------------------------------------------------

# worktree 디렉터리가 메인 작업 트리의 추적되지 않는 파일로 잡히지 않도록 로컬 무시 목록에 등록한다.
# .gitignore를 수정하면 커밋 대상 변경이 생기므로, 저장소에 공유되지 않는 info/exclude를 사용한다.
if ! git -C "$main_worktree" check-ignore -q "$WORKTREE_DIR/"; then
  common_dir="$(cd "$main_worktree" && cd "$(git rev-parse --git-common-dir)" && pwd)"
  mkdir -p "$common_dir/info"
  printf '\n# git-worktree 스킬이 생성하는 작업 디렉터리\n/%s/\n' "$WORKTREE_DIR" >> "$common_dir/info/exclude"
  log "Git 로컬 무시 목록에 worktree 디렉터리를 등록했습니다: $common_dir/info/exclude"
fi

mkdir -p "$worktree_root"
log "worktree를 생성합니다: $worktree_path (브랜치: $branch, 기준: $base_label)"
# 기준 브랜치가 upstream으로 설정되지 않도록 --no-track을 사용한다. upstream은 push 단계에서 설정한다.
if ! add_output="$(git worktree add --quiet --no-track -b "$branch" "$worktree_path" "$base_sha" 2>&1)"; then
  die 1 "worktree를 생성하지 못했습니다. 경로가 git worktree 목록에 남아 있다면 사용자에게 확인한 뒤 git worktree prune을 실행하세요.
$add_output"
fi

created_branch="$(git -C "$worktree_path" symbolic-ref --quiet --short HEAD || true)"
created_head="$(git -C "$worktree_path" rev-parse HEAD 2>/dev/null || true)"
if [ "$created_branch" != "$branch" ] || [ "$created_head" != "$base_sha" ]; then
  die 1 "생성한 worktree의 상태가 예상과 다릅니다. (브랜치: ${created_branch:-없음}, 커밋: ${created_head:-없음})"
fi

log "worktree를 생성했습니다. 이후 작업은 이 경로에서 진행하세요: $worktree_path"
print_result created
