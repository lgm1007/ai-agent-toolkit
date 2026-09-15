#!/usr/bin/env bash
#
# develop-by-docs 스킬 규칙에 따라 설계 문서 기반 구현을 시작하기 전에 작업 브랜치, 작업 트리, 설계 문서를 확인한다.
#
# 보호 브랜치 확인, 설계 문서 검증(docs-create 스킬의 check-doc.sh), 요구사항과 작업 목록 요약, 빌드 도구 감지를
# 이 스크립트가 일괄 처리하므로 어떤 에이전트가 실행하더라도 같은 조건에서 구현을 시작한다.
#
# 사용법:
#   preflight.sh <설계 문서 경로> [--allow-dirty] [--allow-invalid-doc]
#
# 결과 (표준 출력, key=value 형식):
#   RESULT=ready
#   BRANCH=<현재 작업 브랜치>
#   DOC_PATH=<설계 문서 절대 경로>
#   DOC_STATUS=<문서 상태>
#   REQUIREMENTS=<요구사항 ID 수>
#   TASKS=<4.1 작업 목록의 체크리스트 항목 수>
#   UNRESOLVED=<6.3 미결정 사항의 목록 항목 수>
#   BUILD_TOOL=<감지한 빌드 도구, 찾지 못하면 unknown>
#
# 종료 코드:
#   0  구현 준비 완료
#   1  저장소 상태 오류 (Git 저장소 아님, detached HEAD, 진행 중인 작업, 필요한 스크립트 없음)
#   2  인자 오류
#   3  보호 브랜치에서 실행
#   4  커밋되지 않은 변경 사항 존재 (설계 문서 자신의 변경은 제외)
#   5  설계 문서 없음 또는 docs-create 규칙 위반
#
# 요구 사항: bash 3.2 이상, git 2.23 이상, awk, docs-create 스킬의 scripts/check-doc.sh

set -euo pipefail

readonly PROTECTED_BRANCHES="main master develop dev development"

log()  { printf '[develop-by-docs] %s\n' "$*" >&2; }
warn() { printf '[develop-by-docs] 경고: %s\n' "$*" >&2; }
die() {
  local code="$1"
  shift
  printf '[develop-by-docs] 오류: %s\n' "$*" >&2
  exit "$code"
}

usage() {
  cat <<'EOF'
사용법: preflight.sh <설계 문서 경로> [옵션]

설계 문서 기반 구현을 시작하기 전에 작업 브랜치, 작업 트리, 설계 문서를 확인한다.

옵션:
  --allow-dirty         커밋되지 않은 변경 사항이 있어도 진행한다 (사용자 승인 필요)
  --allow-invalid-doc   설계 문서가 docs-create 규칙에 맞지 않아도 진행한다 (사용자 승인 필요)
  -h, --help            도움말을 출력한다
EOF
}

# ---------------------------------------------------------------------------
# 인자 해석
# ---------------------------------------------------------------------------

doc=""
allow_dirty=false
allow_invalid_doc=false

while [ $# -gt 0 ]; do
  case "$1" in
    --allow-dirty)       allow_dirty=true; shift ;;
    --allow-invalid-doc) allow_invalid_doc=true; shift ;;
    -h|--help)           usage; exit 0 ;;
    -*)                  die 2 "알 수 없는 옵션입니다: $1" ;;
    *)
      [ -z "$doc" ] || die 2 "설계 문서 경로는 하나만 입력할 수 있습니다: $1"
      doc="$1"
      shift
      ;;
  esac
done

[ -n "$doc" ] || { usage >&2; die 2 "설계 문서 경로를 입력해야 합니다."; }

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
check_doc_script="$script_dir/../../docs-create/scripts/check-doc.sh"
build_script="$script_dir/build.sh"
[ -f "$check_doc_script" ] \
  || die 1 "docs-create 스킬의 check-doc.sh를 찾을 수 없습니다. docs-create 스킬이 같은 skills 디렉터리에 있어야 합니다: $check_doc_script"

# ---------------------------------------------------------------------------
# 저장소와 작업 브랜치 확인
# ---------------------------------------------------------------------------

[ "$(git rev-parse --is-inside-work-tree 2>/dev/null || true)" = true ] \
  || die 1 "구현할 Git 저장소의 작업 트리 안에서 실행해야 합니다."

for state in rebase-merge rebase-apply MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD BISECT_LOG; do
  if [ -e "$(git rev-parse --git-path "$state")" ]; then
    die 1 "진행 중인 Git 작업이 있습니다. 해당 작업을 완료하거나 중단한 뒤 다시 실행하세요: $state"
  fi
done

branch="$(git symbolic-ref --quiet --short HEAD || true)"
[ -n "$branch" ] || die 1 "HEAD가 브랜치를 가리키지 않는 상태(detached HEAD)입니다. 작업 브랜치로 전환한 뒤 다시 실행하세요."

case " $PROTECTED_BRANCHES " in
  *" $branch "*)
    die 3 "보호 브랜치에서는 구현하지 않습니다: '$branch'. git-branch 스킬이나 git-worktree 스킬로 작업 브랜치를 만들지 사용자에게 확인하세요."
    ;;
esac

case "$branch" in
  feat/*|fix/*|refactor/*|chore/*|docs/*|test/*) ;;
  *) warn "브랜치 이름이 git-branch 스킬 규칙(<prefix>/<작업명>)과 다릅니다: '$branch'" ;;
esac

# ---------------------------------------------------------------------------
# 설계 문서 검증
# ---------------------------------------------------------------------------

[ -f "$doc" ] || die 5 "설계 문서를 찾을 수 없습니다: $doc"
doc_path="$(cd "$(dirname "$doc")" && pwd -P)/$(basename "$doc")"

check_status=0
check_output="$(bash "$check_doc_script" "$doc_path" 2>&1 >/dev/null)" || check_status=$?

case "$check_status" in
  0) ;;
  3)
    printf '%s\n' "$check_output" >&2
    if [ "$allow_invalid_doc" = false ]; then
      die 5 "설계 문서가 docs-create 규칙에 맞지 않습니다. 문서를 고칠지, 이대로 구현할지(--allow-invalid-doc) 사용자에게 확인하세요."
    fi
    warn "--allow-invalid-doc 옵션에 따라 docs-create 규칙에 맞지 않는 설계 문서로 구현을 준비합니다."
    ;;
  *)
    printf '%s\n' "$check_output" >&2
    die 1 "설계 문서를 검증하지 못했습니다."
    ;;
esac

metadata_value() {
  local value
  value="$(LC_ALL=C sed -n "s/^| *$1 *| *\\([^|]*[^ |]\\) *|.*\$/\\1/p" "$doc_path")"
  printf '%s' "${value%%$'\n'*}"
}

doc_status="$(metadata_value 상태)"
[ -n "$doc_status" ] || doc_status="-"
if [ "$doc_status" = 초안 ]; then
  warn "설계 문서가 초안 상태입니다. 초안 문서로 구현을 시작한다는 사실을 사용자에게 알리세요."
fi

doc_issue="$(metadata_value '관련 이슈')"
doc_issue_pattern='^#([0-9]+)$'
branch_issue_pattern='^[a-z]+/([0-9]+)-'
if [[ "$doc_issue" =~ $doc_issue_pattern ]]; then
  doc_issue_number="${BASH_REMATCH[1]}"
  if [[ "$branch" =~ $branch_issue_pattern ]] && [ "${BASH_REMATCH[1]}" != "$doc_issue_number" ]; then
    warn "브랜치의 이슈 번호(#${BASH_REMATCH[1]})가 설계 문서의 관련 이슈(#$doc_issue_number)와 다릅니다. 올바른 브랜치인지 사용자에게 확인하세요."
  fi
fi

# 제목($1)부터 같은 수준 이상의 다음 제목 전까지의 본문을 출력한다. 코드 블록 안의 줄은 제목으로 보지 않는다.
section_body() {
  DOC_SECTION="$1" LC_ALL=C awk '
    function level_of(text) {
      match(text, /^#+/)
      return RLENGTH
    }
    {
      if ($0 ~ /^[ \t]*(```|~~~)/) in_code = !in_code
      if (!in_code && $0 ~ /^#+ /) {
        if (inside && level_of($0) <= target_level) exit
        if ($0 == ENVIRON["DOC_SECTION"]) {
          inside = 1
          target_level = level_of($0)
          next
        }
      }
      if (inside) print
    }' "$doc_path"
}

requirement_ids="$(section_body '## 2. 요구사항' | { grep -oE '(NFR|FR)-[0-9]+' || true; } | LC_ALL=C sort -u)"
requirements=0
if [ -n "$requirement_ids" ]; then
  requirements="$(printf '%s\n' "$requirement_ids" | wc -l | tr -d ' ')"
fi

tasks="$(section_body '### 4.1 작업 목록' | { grep -cE '^[[:space:]]*[-*] \[[ xX]\] ' || true; })"

unresolved_items="$(section_body '### 6.3 미결정 사항' \
  | { grep -E '^[[:space:]]*([-*]|[0-9]+\.) ' || true; } \
  | { grep -vE '^[[:space:]]*([-*]|[0-9]+\.) +(없음|해당 없음)\.?[[:space:]]*$' || true; })"
unresolved=0
if [ -n "$unresolved_items" ]; then
  unresolved="$(printf '%s\n' "$unresolved_items" | wc -l | tr -d ' ')"
  log "6.3 미결정 사항 (${unresolved}개):"
  printf '%s\n' "$unresolved_items" | LC_ALL=C sed 's/^[[:space:]]*/    /' >&2
fi

[ "$requirements" -gt 0 ] || warn "설계 문서의 2. 요구사항에서 요구사항 ID(FR-1, NFR-1 등)를 찾지 못했습니다."
[ "$tasks" -gt 0 ] || warn "설계 문서의 4.1 작업 목록에서 체크리스트 항목을 찾지 못했습니다."

# ---------------------------------------------------------------------------
# 작업 트리 확인 (설계 문서 자신의 변경은 제외)
# ---------------------------------------------------------------------------

repo_root="$(git rev-parse --show-toplevel)"
doc_relative="${doc_path#"$repo_root"/}"

changes="$(git -c core.quotePath=false status --porcelain --untracked-files=all \
  | DOC_RELATIVE="$doc_relative" awk 'substr($0, 4) != ENVIRON["DOC_RELATIVE"]')"

if [ -n "$changes" ]; then
  if [ "$allow_dirty" = false ]; then
    log "커밋되지 않은 변경 사항:"
    printf '%s\n' "$changes" >&2
    die 4 "커밋되지 않은 변경 사항이 있습니다. 구현 변경과 섞어도 되는지 사용자에게 확인하고, 그대로 진행하려면 --allow-dirty 옵션을 추가하세요."
  fi
  warn "--allow-dirty 옵션에 따라 커밋되지 않은 변경 사항이 있는 상태로 구현을 준비합니다."
fi

# ---------------------------------------------------------------------------
# 빌드 도구 감지와 결과 출력
# ---------------------------------------------------------------------------

build_tool=unknown
if [ -f "$build_script" ] && detect_output="$(bash "$build_script" --detect-only 2>/dev/null)"; then
  build_tool="$(sed -n 's/^BUILD_TOOL=//p' <<< "$detect_output")"
  [ -n "$build_tool" ] || build_tool=unknown
fi
if [ "$build_tool" = unknown ]; then
  warn "빌드 도구를 자동으로 찾지 못했습니다. 빌드할 때 사용자에게 빌드 명령을 확인하고 build.sh --command로 지정하세요."
fi

log "구현을 시작할 준비가 되었습니다: $branch ($doc_relative)"
printf 'RESULT=ready\n'
printf 'BRANCH=%s\n' "$branch"
printf 'DOC_PATH=%s\n' "$doc_path"
printf 'DOC_STATUS=%s\n' "$doc_status"
printf 'REQUIREMENTS=%s\n' "$requirements"
printf 'TASKS=%s\n' "$tasks"
printf 'UNRESOLVED=%s\n' "$unresolved"
printf 'BUILD_TOOL=%s\n' "$build_tool"
