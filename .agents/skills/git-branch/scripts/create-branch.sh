#!/usr/bin/env bash
#
# git-branch 스킬 규칙에 따라 개발 브랜치에서 새 작업 브랜치를 생성한다.
#
# 브랜치명 조합과 검증, 기준 브랜치 탐색, 중복 확인을 이 스크립트가 일괄 처리하므로
# 어떤 에이전트가 실행하더라도 같은 규칙으로 브랜치가 생성된다.
#
# 사용법:
#   create-branch.sh <prefix> <영문 작업명...> [옵션]
#
# 예시:
#   create-branch.sh feat "add kakao social login"
#   create-branch.sh feat "add coupon expiry notification" --issue 128
#   create-branch.sh chore "upgrade spring boot 3.3" --dry-run
#
# 결과 (표준 출력, key=value 형식):
#   RESULT=created | dry-run
#   BRANCH=<브랜치명>
#   BASE=<기준 브랜치>
#   BASE_COMMIT=<기준 커밋>
#   CARRIED_CHANGES=true | false
#
# 종료 코드:
#   0  성공
#   1  저장소 상태 오류 또는 git 명령 실패
#   2  인자 오류
#   3  브랜치명 길이 초과
#   4  커밋되지 않은 변경 사항 존재
#   5  기준 브랜치를 찾을 수 없거나 후보가 여러 개
#   6  같은 이름의 브랜치가 이미 존재
#   7  원격 저장소 조회 또는 fetch 실패
#
# 요구 사항: bash 3.2 이상, git 2.23 이상

set -euo pipefail

readonly ALLOWED_PREFIXES="feat fix refactor chore docs test"
readonly BASE_CANDIDATES="develop dev development"
readonly PROTECTED_BASES="main master"
readonly MAX_LENGTH=50

# 인증 정보가 없을 때 입력 대기로 멈추지 않고 바로 실패하도록 한다.
export GIT_TERMINAL_PROMPT=0

log()  { printf '[git-branch] %s\n' "$*" >&2; }
warn() { printf '[git-branch] 경고: %s\n' "$*" >&2; }
die() {
  local code="$1"
  shift
  printf '[git-branch] 오류: %s\n' "$*" >&2
  exit "$code"
}

usage() {
  cat <<'EOF'
사용법: create-branch.sh <prefix> <영문 작업명...> [옵션]

prefix:
  feat | fix | refactor | chore | docs | test

옵션:
  --issue <번호>      이슈 번호를 prefix 뒤에 붙인다 (예: feat/128-add-login)
  --base <브랜치>     기준 브랜치를 지정한다 (기본: develop, dev, development 자동 탐색)
  --remote <이름>     원격 저장소 이름 (기본: origin)
  --no-fetch          원격 저장소에 접속하지 않고 마지막으로 fetch한 정보를 사용한다
  --allow-dirty       커밋되지 않은 변경 사항을 새 브랜치로 가져간다 (사용자 승인 필요)
  --allow-long        50자를 넘는 브랜치명을 허용한다 (사용자 승인 필요)
  --allow-main-base   main/master를 기준 브랜치로 허용한다 (사용자 승인 필요)
  --dry-run           검증과 fetch까지만 수행하고 브랜치는 생성하지 않는다
  -h, --help          도움말을 출력한다
EOF
}

# ---------------------------------------------------------------------------
# 인자 해석
# ---------------------------------------------------------------------------

prefix=""
description=""
issue=""
base=""
remote="origin"
remote_explicit=false
no_fetch=false
allow_dirty=false
allow_long=false
allow_main_base=false
dry_run=false

need_value() {
  [ "$2" -ge 2 ] || die 2 "옵션에 값이 필요합니다: $1"
}

# 첫 번째 위치 인자는 prefix, 나머지는 공백으로 이어 붙여 작업명으로 사용한다.
add_positional() {
  if [ -z "$prefix" ]; then
    prefix="$1"
  else
    description="${description:+$description }$1"
  fi
}

while [ $# -gt 0 ]; do
  case "$1" in
    --issue)           need_value "$1" $#; issue="$2"; shift 2 ;;
    --issue=*)         issue="${1#*=}"; shift ;;
    --base)            need_value "$1" $#; base="$2"; shift 2 ;;
    --base=*)          base="${1#*=}"; shift ;;
    --remote)          need_value "$1" $#; remote="$2"; remote_explicit=true; shift 2 ;;
    --remote=*)        remote="${1#*=}"; remote_explicit=true; shift ;;
    --no-fetch)        no_fetch=true; shift ;;
    --allow-dirty)     allow_dirty=true; shift ;;
    --allow-long)      allow_long=true; shift ;;
    --allow-main-base) allow_main_base=true; shift ;;
    --dry-run)         dry_run=true; shift ;;
    -h|--help)         usage; exit 0 ;;
    --)                shift; while [ $# -gt 0 ]; do add_positional "$1"; shift; done ;;
    -*)                die 2 "알 수 없는 옵션입니다: $1" ;;
    *)                 add_positional "$1"; shift ;;
  esac
done

# ---------------------------------------------------------------------------
# 브랜치명 조합과 검증 (저장소에 접근하지 않는 검사)
# ---------------------------------------------------------------------------

[ -n "$prefix" ] || { usage >&2; die 2 "prefix를 입력해야 합니다."; }

prefix="$(printf '%s' "${prefix%/}" | tr '[:upper:]' '[:lower:]')"
[[ "$prefix" =~ ^[a-z]+$ ]] || die 2 "허용되지 않는 prefix입니다: '$prefix' (허용: $ALLOWED_PREFIXES)"
case " $ALLOWED_PREFIXES " in
  *" $prefix "*) ;;
  *) die 2 "허용되지 않는 prefix입니다: '$prefix' (허용: $ALLOWED_PREFIXES)" ;;
esac

# 줄바꿈과 탭은 공백으로 바꾸고 앞뒤 공백을 제거한다.
description="$(printf '%s' "$description" | tr '\r\n\t' '   ' | sed -E 's/^ +//; s/ +$//')"
[ -n "$description" ] || die 2 "영문 작업명을 입력해야 합니다."

if LC_ALL=C grep -q '[^[:print:]]' <<< "$description"; then
  die 2 "작업명에 영문이 아닌 문자가 있습니다. 작업 설명을 영문으로 번역해서 전달하세요: '$description'"
fi

lower_description="$(printf '%s' "$description" | tr '[:upper:]' '[:lower:]')"
for allowed in $ALLOWED_PREFIXES; do
  case "$lower_description" in
    "$allowed"/*) die 2 "작업명에는 prefix를 빼고 전달하세요: '$description'" ;;
  esac
done

# 영문 소문자, 숫자, '-'만 남긴다. 따옴표는 지우고 나머지 문자는 '-'로 바꾼다.
slug="$(printf '%s' "$lower_description" \
  | tr -d "'\"\`" \
  | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')"
[ -n "$slug" ] || die 2 "작업명에 영문자나 숫자가 없습니다: '$description'"

if [ "${slug%%-*}" = "$prefix" ]; then
  die 2 "작업명이 prefix와 같은 단어로 시작합니다. 중복되는 단어를 빼고 다시 실행하세요: '$prefix/$slug'"
fi

if [ -n "$issue" ]; then
  issue="${issue#\#}"
  [[ "$issue" =~ ^[0-9]+$ ]] || die 2 "이슈 번호는 숫자만 입력할 수 있습니다: '$issue'"
  slug="$issue-$slug"
fi

branch="$prefix/$slug"

if [ "${#branch}" -gt "$MAX_LENGTH" ]; then
  if [ "$allow_long" = true ]; then
    warn "브랜치명이 ${#branch}자로 ${MAX_LENGTH}자를 넘지만 --allow-long 옵션에 따라 진행합니다."
  else
    die 3 "브랜치명이 ${#branch}자로 ${MAX_LENGTH}자를 넘습니다. 핵심 키워드만 남기고 다시 실행하세요: '$branch'"
  fi
fi

git check-ref-format "refs/heads/$branch" || die 2 "Git 브랜치명 형식에 맞지 않습니다: '$branch'"

if [ -n "$base" ]; then
  # refs/heads/develop, origin/develop처럼 전달해도 브랜치 이름만 사용한다.
  base="${base#refs/heads/}"
  base="${base#"$remote"/}"
  case "$base" in
    -*) die 2 "기준 브랜치 이름이 올바르지 않습니다: '$base'" ;;
  esac
  git check-ref-format "refs/heads/$base" || die 2 "기준 브랜치 이름이 올바르지 않습니다: '$base'"

  case " $PROTECTED_BASES " in
    *" $base "*)
      [ "$allow_main_base" = true ] \
        || die 2 "규칙상 main/master에서는 브랜치를 파생하지 않습니다. 사용자가 명시적으로 요청한 경우에만 --allow-main-base 옵션을 추가하세요: '$base'"
      warn "--allow-main-base 옵션에 따라 '$base' 브랜치에서 파생합니다."
      ;;
  esac
fi

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

# ---------------------------------------------------------------------------
# 원격 저장소의 브랜치 목록 확인
# ---------------------------------------------------------------------------

remotes="$(git remote)"
has_remote=false
if [ -n "$remotes" ] && grep -Fxq -- "$remote" <<< "$remotes"; then
  has_remote=true
elif [ "$remote_explicit" = true ]; then
  die 2 "원격 저장소를 찾을 수 없습니다: '$remote' (등록된 원격 저장소: $(printf '%s' "${remotes:-없음}" | tr '\n' ' '))"
else
  warn "원격 저장소를 찾을 수 없어 로컬 브랜치만 확인합니다: '$remote'"
fi

remote_branches=""
if [ "$has_remote" = true ]; then
  if [ "$no_fetch" = true ]; then
    log "--no-fetch 옵션에 따라 마지막으로 fetch한 원격 브랜치 정보를 사용합니다."
    remote_branches="$(git for-each-ref --format='%(refname:lstrip=3)' "refs/remotes/$remote/")"
  else
    log "원격 저장소의 브랜치 목록을 조회합니다: $remote"
    if ! ls_remote_output="$(git ls-remote --heads "$remote" 2>&1)"; then
      die 7 "원격 저장소 조회에 실패했습니다. 네트워크와 인증 상태를 확인하세요: $remote
$ls_remote_output"
    fi
    remote_branches="$(sed -n 's#^[0-9a-f]*[[:space:]]*refs/heads/##p' <<< "$ls_remote_output")"
  fi
fi

remote_has_branch() {
  [ -n "$remote_branches" ] && grep -Fxq -- "$1" <<< "$remote_branches"
}

local_has_branch() {
  git show-ref --verify --quiet "refs/heads/$1"
}

# ---------------------------------------------------------------------------
# 기준 브랜치 결정
# ---------------------------------------------------------------------------

if [ -n "$base" ]; then
  candidates="$base"
else
  candidates="$BASE_CANDIDATES"
fi

found=""
for candidate in $candidates; do
  if remote_has_branch "$candidate" || local_has_branch "$candidate"; then
    found="${found:+$found }$candidate"
  fi
done

if [ -z "$found" ]; then
  [ -z "$base" ] || die 5 "기준 브랜치를 로컬과 원격 저장소에서 찾을 수 없습니다: '$base'"
  die 5 "개발 브랜치($BASE_CANDIDATES)를 찾을 수 없습니다. 사용자에게 기준 브랜치를 확인한 뒤 --base 옵션으로 지정하세요."
fi
case "$found" in
  *" "*) die 5 "개발 브랜치 후보가 여러 개입니다($found). 사용자에게 기준 브랜치를 확인한 뒤 --base 옵션으로 지정하세요." ;;
esac
base="$found"

# ---------------------------------------------------------------------------
# 브랜치 중복 확인 (대소문자를 구분하지 않는 파일 시스템을 고려한다)
# ---------------------------------------------------------------------------

conflict_label() {
  if [ "$1" = "$branch" ]; then
    printf '같은 이름의 브랜치'
  else
    printf '대소문자만 다른 브랜치'
  fi
}

local_branches="$(git for-each-ref --format='%(refname:lstrip=2)' refs/heads/)"
if [ -n "$local_branches" ] && conflict="$(grep -Fxi -m 1 -- "$branch" <<< "$local_branches")"; then
  if [ "$conflict" = "$(git symbolic-ref --quiet --short HEAD || true)" ]; then
    die 6 "이미 생성되어 체크아웃된 브랜치입니다: '$conflict'"
  fi
  die 6 "로컬에 $(conflict_label "$conflict")가 이미 있습니다: '$conflict'"
fi

if [ -n "$remote_branches" ] && conflict="$(grep -Fxi -m 1 -- "$branch" <<< "$remote_branches")"; then
  die 6 "원격 저장소에 $(conflict_label "$conflict")가 이미 있습니다: '$remote/$conflict'"
fi

# ---------------------------------------------------------------------------
# 작업 트리 상태 확인
# ---------------------------------------------------------------------------

carried_changes=false
changes="$(git status --porcelain --untracked-files=normal)"
if [ -n "$changes" ]; then
  if [ "$allow_dirty" = false ]; then
    log "커밋되지 않은 변경 사항:"
    printf '%s\n' "$changes" >&2
    die 4 "커밋되지 않은 변경 사항이 있습니다. 사용자에게 처리 방법을 확인하고, 새 브랜치로 가져가려면 --allow-dirty 옵션을 추가하세요."
  fi
  carried_changes=true
  warn "--allow-dirty 옵션에 따라 커밋되지 않은 변경 사항을 새 브랜치로 가져갑니다."
fi

# ---------------------------------------------------------------------------
# 기준 커밋 결정
# ---------------------------------------------------------------------------

if remote_has_branch "$base"; then
  start_ref="refs/remotes/$remote/$base"
  base_label="$remote/$base"
  if [ "$no_fetch" = false ]; then
    log "기준 브랜치의 최신 상태를 가져옵니다: $base_label"
    # 단일 브랜치 clone처럼 fetch refspec이 제한된 저장소에서도 동작하도록 refspec을 명시한다.
    if ! fetch_output="$(git fetch --quiet "$remote" "+refs/heads/$base:$start_ref" 2>&1)"; then
      die 7 "기준 브랜치를 fetch하지 못했습니다: $base_label
$fetch_output"
    fi
  fi
  if local_has_branch "$base"; then
    unpushed="$(git rev-list --count "$start_ref..refs/heads/$base")"
    if [ "$unpushed" -gt 0 ]; then
      warn "로컬 '$base' 브랜치에 원격 저장소에 없는 커밋이 ${unpushed}개 있습니다. 이 커밋은 새 브랜치에 포함되지 않습니다."
    fi
  fi
else
  start_ref="refs/heads/$base"
  base_label="$base"
  if [ "$has_remote" = true ]; then
    warn "원격 저장소에 기준 브랜치가 없어 로컬 브랜치를 기준으로 사용합니다: '$base'"
  fi
fi

base_commit="$(git rev-parse --short "$start_ref")"

print_result() {
  printf 'RESULT=%s\n' "$1"
  printf 'BRANCH=%s\n' "$branch"
  printf 'BASE=%s\n' "$base_label"
  printf 'BASE_COMMIT=%s\n' "$base_commit"
  printf 'CARRIED_CHANGES=%s\n' "$carried_changes"
}

if [ "$dry_run" = true ]; then
  log "--dry-run 옵션에 따라 브랜치를 생성하지 않습니다."
  print_result dry-run
  exit 0
fi

# ---------------------------------------------------------------------------
# 브랜치 생성
# ---------------------------------------------------------------------------

log "브랜치를 생성합니다: $branch (기준: $base_label)"
# 기준 브랜치가 upstream으로 설정되지 않도록 --no-track을 사용한다. upstream은 push 단계에서 설정한다.
if ! switch_output="$(git switch --no-track -c "$branch" "$start_ref" 2>&1)"; then
  die 1 "브랜치를 생성하지 못했습니다: $branch
$switch_output"
fi

print_result created
