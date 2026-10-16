#!/usr/bin/env bash
#
# git-pr-code-review 스킬 규칙에 따라 GitHub PR의 리뷰 근거를 수집하고 자동 검사를 실행한다.
#
# PR 정보, 변경 내용(diff), 변경 파일 목록, 연결된 이슈, 설계 문서, 기존 리뷰와 코멘트, CI 결과를
# 작업 디렉터리에 파일로 저장하고, 추가한 줄에서 충돌 표시, 민감 정보, 디버그 출력, TODO를 찾는다.
# 로컬 저장소에 PR의 base 저장소를 가리키는 원격 저장소가 있으면 PR 커밋을 fetch해서,
# 브랜치를 바꾸지 않고 git show <head 커밋>:<파일 경로>로 PR 코드를 읽을 수 있게 한다.
# 자동 검사 결과는 지적 후보이며, 에이전트가 실제 문제인지 확인한 뒤 리뷰 결과에 반영한다.
#
# 사용법:
#   pr-context.sh [<PR>] [--repo <owner/repo>] [--remote <이름>] [--doc <설계 문서 경로>] [--since <커밋>] [--no-fetch]
#
# 결과 (표준 출력, key=value 형식):
#   PR:   RESULT=collected, REPO, PR_NUMBER, PR_URL, PR_TITLE, PR_STATE, IS_DRAFT, IS_CROSS_REPOSITORY, AUTHOR,
#         BASE_BRANCH, BASE_COMMIT, HEAD_BRANCH, HEAD_COMMIT, MERGE_BASE, MERGEABLE
#   변경: COMMITS, CHANGED_FILES, ADDED_LINES, DELETED_LINES, TEST_FILES_CHANGED, GENERATED_FILES
#   로컬: LOCAL_CODE, REMOTE, WORKTREE_IS_HEAD, SINCE
#   근거: ISSUES, DOC_PATH, DOC_FILE, CHECKS_TOTAL, CHECKS_PASSED, CHECKS_FAILED, CHECKS_PENDING,
#         REVIEWS, REVIEW_COMMENTS, COMMENTS, LAST_REVIEW_COMMIT, AUTO_FINDINGS
#   파일: WORK_DIR, PR_PATH, DIFF_PATH, SINCE_DIFF_PATH, FILES_PATH, ISSUES_PATH, DISCUSSION_PATH,
#         CHECKS_PATH, FINDINGS_PATH
#
# 종료 코드:
#   0  수집 완료
#   1  gh 명령 실패 또는 환경 오류
#   2  인자 오류
#   3  PR을 찾을 수 없거나 리뷰할 변경 사항이 없음
#   4  gh 미설치 또는 미인증
#   5  PR 커밋 fetch 실패
#   6  재리뷰 기준 커밋을 찾을 수 없음
#   7  PR diff 조회 실패
#
# 요구 사항: bash 3.2 이상, GitHub CLI(gh) 2.72 이상, git 2.23 이상(로컬 코드 사용 시), awk

set -euo pipefail

readonly MAX_ISSUES=10

# gh와 git이 입력을 기다리거나 업데이트 안내를 출력하지 않도록 한다.
export GH_PROMPT_DISABLED=1
export GH_NO_UPDATE_NOTIFIER=1
export GIT_TERMINAL_PROMPT=0

log()  { printf '[git-pr-code-review] %s\n' "$*" >&2; }
warn() { printf '[git-pr-code-review] 경고: %s\n' "$*" >&2; }
die() {
  local code="$1"
  shift
  printf '[git-pr-code-review] 오류: %s\n' "$*" >&2
  exit "$code"
}

usage() {
  cat <<'EOF'
사용법: pr-context.sh [<PR>] [옵션]

<PR>은 PR 번호, URL, head 브랜치 이름 중 하나다. 생략하면 현재 브랜치에 연결된 PR을 사용한다.

옵션:
  --repo <owner/repo>      PR이 있는 저장소 (기본: 현재 디렉터리의 저장소)
  --remote <이름>          PR의 base 저장소를 가리키는 원격 저장소 (기본: 원격 저장소 주소로 자동 탐색)
  --doc <설계 문서 경로>   함께 확인할 설계 문서 (기본: 연결된 이슈 번호로 PR head 커밋에서 탐색)
  --since <커밋>           이 커밋 이후의 변경만 자동 검사한다 (재리뷰용)
  --no-fetch               원격 저장소에서 PR 커밋을 가져오지 않고 로컬에 있는 커밋만 사용한다
  -h, --help               도움말을 출력한다
EOF
}

need_value() {
  [ "$2" -ge 2 ] || die 2 "옵션에 값이 필요합니다: $1"
  case "$3" in
    ""|-*) die 2 "옵션 값이 올바르지 않습니다: $1 '$3'" ;;
  esac
}

# ---------------------------------------------------------------------------
# 인자 해석
# ---------------------------------------------------------------------------

pr_arg=""
repo_arg=""
remote_arg=""
doc_arg=""
since_arg=""
no_fetch=false

while [ $# -gt 0 ]; do
  case "$1" in
    --repo)     need_value "$1" $# "${2:-}"; repo_arg="$2"; shift 2 ;;
    --remote)   need_value "$1" $# "${2:-}"; remote_arg="$2"; shift 2 ;;
    --doc)      need_value "$1" $# "${2:-}"; doc_arg="$2"; shift 2 ;;
    --since)    need_value "$1" $# "${2:-}"; since_arg="$2"; shift 2 ;;
    --no-fetch) no_fetch=true; shift ;;
    -h|--help)  usage; exit 0 ;;
    -*)         die 2 "알 수 없는 옵션입니다: $1" ;;
    *)
      [ -z "$pr_arg" ] || die 2 "PR은 하나만 지정할 수 있습니다: $1"
      pr_arg="$1"
      shift
      ;;
  esac
done

if [ -n "$repo_arg" ]; then
  repo_pattern='^([A-Za-z0-9.-]+/)?[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$'
  [[ "$repo_arg" =~ $repo_pattern ]] || die 2 "저장소는 owner/repo 형식으로 입력해야 합니다: '$repo_arg'"
  case "$pr_arg" in
    http://*|https://*) die 2 "PR URL을 사용할 때는 --repo 옵션을 함께 지정하지 않습니다." ;;
  esac
fi

# ---------------------------------------------------------------------------
# 공통 함수
# ---------------------------------------------------------------------------

absolute_path() {
  printf '%s/%s' "$(cd "$(dirname "$1")" && pwd -P)" "$(basename "$1")"
}

line_count() {
  if [ -z "$1" ]; then
    printf '0'
  else
    printf '%s\n' "$1" | wc -l | tr -d ' '
  fi
}

lowercase() {
  printf '%s' "$1" | LC_ALL=C tr '[:upper:]' '[:lower:]'
}

# diff 해석에 사용하는 awk 함수 모음이다.
# git은 특수 문자나 한글이 들어간 경로를 "a/\355\225\234..." 형식으로 감싸므로 원래 경로로 되돌린다.
read -r -d '' AWK_LIB <<'AWK' || true
function decode_path(p,    out, i, c, n) {
  if (substr(p, 1, 1) != "\"" || substr(p, length(p), 1) != "\"") return p
  if (!byte_ready) {
    for (i = 0; i < 256; i++) byte[sprintf("%03o", i)] = sprintf("%c", i)
    byte_ready = 1
  }
  p = substr(p, 2, length(p) - 2)
  out = ""
  for (i = 1; i <= length(p); i++) {
    c = substr(p, i, 1)
    if (c != "\\") { out = out c; continue }
    n = substr(p, i + 1, 1)
    if (n ~ /[0-7]/) { out = out byte[substr(p, i + 1, 3)]; i += 3 }
    else if (n == "t") { out = out "\t"; i++ }
    else if (n == "n") { out = out "\n"; i++ }
    else { out = out n; i++ }
  }
  return out
}
# ---/+++ 줄의 경로를 해석한다. 공백이 있는 경로 끝의 탭을 지우고, a/ b/ 접두사를 뗀다.
function clean_path(p) {
  sub(/\t$/, "", p)
  p = decode_path(p)
  if (p != "/dev/null") sub(/^[ab]\//, "", p)
  return p
}
# "diff --git a/<경로> b/<경로>" 줄에서 변경 후 경로를 꺼낸다. (바이너리 파일, 권한만 바뀐 파일용)
function git_header_path(s,    i) {
  i = index(s, " \"b/")
  if (i > 0) return clean_path(substr(s, i + 1))
  i = index(s, " b/")
  if (i > 0) return substr(s, i + 3)
  return s
}
function base_name(p) {
  sub(/.*\//, "", p)
  return p
}
function file_kind(p,    lower, name) {
  lower = tolower(p)
  name = base_name(lower)
  if (name ~ /^(package-lock\.json|npm-shrinkwrap\.json|yarn\.lock|pnpm-lock\.yaml|bun\.lockb?|gemfile\.lock|cargo\.lock|poetry\.lock|pipfile\.lock|uv\.lock|composer\.lock|go\.sum|gradle\.lockfile)$/ ||
      name ~ /\.(min\.js|min\.css|map|snap)$/ || name ~ /\.generated\./ || name ~ /(_pb2\.py|\.pb\.go)$/ ||
      lower ~ /(^|\/)__snapshots__\//) return "generated"
  if (lower ~ /^(test|tests|spec|__tests__)\// || lower ~ /\/(test|tests|spec|__tests__)\// ||
      p ~ /Tests?\.(java|kt)$/ || name ~ /_test\.(go|py)$/ || name ~ /^test_.*\.py$/ ||
      name ~ /\.(test|spec)\.(js|jsx|ts|tsx)$/) return "test"
  if (name ~ /\.(java|kt|go|py|js|jsx|ts|tsx|rs|rb|php|cs|swift|scala|c|cc|cpp|h)$/) return "source"
  return "other"
}
function is_sensitive(p,    name) {
  name = base_name(tolower(p))
  if (name ~ /\.(example|sample|template|pub)$/) return 0
  if (name ~ /^\.env(\..*)?$/ || name ~ /\.(pem|key|p12|pfx|jks|keystore|tfvars|secret)$/) return 1
  if (name ~ /^(id_rsa|id_dsa|id_ecdsa|id_ed25519)/ || name ~ /^credentials(\..*)?$/ || name ~ /^secrets\./) return 1
  if (name == ".netrc" || name == ".pypirc") return 1
  return 0
}
AWK

# diff를 해석한다.
#   MODE=files    : 파일마다 "상태<TAB>종류<TAB>경로"를 출력하고, 추가/삭제 줄 수를 STATS_OUT 파일에 쓴다.
#   MODE=findings : 추가한 줄과 변경 파일을 검사해 "심각도 후보|종류|위치|내용"을 출력한다.
read -r -d '' AWK_ANALYZE <<'AWK' || true
function finding(severity, type, location, text) {
  gsub(/\|/, "/", text)
  print severity "|" type "|" location "|" text
}
function trim_text(s) {
  sub(/^[ \t]+/, "", s)
  sub(/[ \t\r]+$/, "", s)
  return substr(s, 1, 120)
}
function flush_file(    kind) {
  if (!in_file) return
  if (path == "") path = header_path
  kind = file_kind(path)
  if (ENVIRON["MODE"] == "files") {
    printf "%s\t%s\t%s\n", status, kind, path
  } else if (status != "D") {
    if (kind == "test") test_files++
    else if (kind == "source") source_files++
    if (is_sensitive(path)) finding("높음", "민감한 파일", path, "민감한 파일로 의심되는 파일이 변경 사항에 있습니다.")
  }
  in_file = 0
}
function start_hunk() {
  if (in_header) {
    in_header = 0
    current_path = (path == "") ? header_path : path
    current_kind = file_kind(current_path)
  }
  if (match($0, /\+[0-9]+/)) new_line = substr($0, RSTART + 1, RLENGTH - 1) - 1
}
function check_added(text,    location) {
  location = current_path ":" new_line
  if (text ~ /^(<<<<<<<|=======|>>>>>>>)( |$)/) finding("높음", "충돌 표시", location, "merge 충돌 표시가 남아 있습니다.")
  if (tolower(text) ~ ENVIRON["SECRET_PATTERN"]) finding("높음", "민감 정보", location, "비밀번호나 키로 의심되는 값이 있습니다. (값은 기록하지 않음)")
  if (text ~ /[ \t]+\r?$/) {
    if (whitespace_count == 0) whitespace_first = location
    whitespace_count++
  }
  if (current_kind == "generated") return
  if (text ~ /console\.log\(|System\.out\.print|printStackTrace\(\)|debugger;|fmt\.Print|var_dump\(/) finding("낮음", "디버그 출력", location, trim_text(text))
  if (text ~ /(TODO|FIXME)/) finding("낮음", "TODO", location, trim_text(text))
}
/^diff --git / {
  flush_file()
  in_file = 1
  in_header = 1
  status = "M"
  path = ""
  old_path = ""
  header_path = git_header_path(substr($0, 12))
  next
}
in_header {
  if ($0 ~ /^new file mode/) status = "A"
  else if ($0 ~ /^deleted file mode/) status = "D"
  else if ($0 ~ /^rename to /) { status = "R"; path = decode_path(substr($0, 11)) }
  else if ($0 ~ /^--- /) old_path = clean_path(substr($0, 5))
  else if ($0 ~ /^\+\+\+ /) { path = clean_path(substr($0, 5)); if (path == "/dev/null") path = old_path }
  else if ($0 ~ /^@@ /) start_hunk()
  next
}
/^@@ / { start_hunk(); next }
/^\+/ {
  new_line++
  added++
  if (ENVIRON["MODE"] == "findings") check_added(substr($0, 2))
  next
}
/^-/ { deleted++; next }
/^ / { new_line++; next }
END {
  flush_file()
  if (ENVIRON["MODE"] == "files") {
    printf "%d\t%d\n", added, deleted > ENVIRON["STATS_OUT"]
  } else {
    if (whitespace_count > 0) finding("낮음", "공백 오류", whitespace_first, "줄 끝 공백이 " whitespace_count "건 있습니다.")
    if (source_files > 0 && test_files == 0) finding("중간", "테스트", "-", "소스 파일 " source_files "개가 변경되었지만 테스트 파일 변경이 없습니다.")
  }
}
AWK

# ---------------------------------------------------------------------------
# GitHub CLI 확인
# ---------------------------------------------------------------------------

command -v gh >/dev/null 2>&1 || die 4 "GitHub CLI(gh)가 설치되어 있지 않습니다. 사용자에게 설치를 요청하세요."

tmp_root="${TMPDIR:-/tmp}"
work_dir="$(mktemp -d "${tmp_root%/}/git-pr-code-review.XXXXXX")" || die 1 "작업 디렉터리를 만들지 못했습니다."
err_file="$work_dir/gh-error.log"

if ! gh auth status >/dev/null 2>"$err_file"; then
  die 4 "GitHub CLI 인증이 필요합니다. 사용자에게 gh auth login 실행을 요청하세요.
$(cat "$err_file")"
fi

# ---------------------------------------------------------------------------
# PR 정보
# ---------------------------------------------------------------------------

pr_jq='"number=\(.number)", "url=\(.url)", "state=\(.state)", "draft=\(.isDraft)", "cross=\(.isCrossRepository)",
  "author=\(.author.login // "")", "base_branch=\(.baseRefName)", "base_oid=\(.baseRefOid)",
  "head_branch=\(.headRefName)", "head_oid=\(.headRefOid)", "mergeable=\(.mergeable)",
  "commits=\(.commits | length)", "title=\(.title)"'

# shellcheck disable=SC2086
if ! pr_info="$(gh pr view ${pr_arg:+"$pr_arg"} ${repo_arg:+-R "$repo_arg"} \
  --json number,url,state,isDraft,isCrossRepository,author,baseRefName,baseRefOid,headRefName,headRefOid,mergeable,commits,title \
  --jq "$pr_jq" 2>"$err_file")"; then
  if grep -qiE 'no pull requests? found|could not resolve to a pull ?request|not found' "$err_file"; then
    die 3 "PR을 찾을 수 없습니다: ${pr_arg:-현재 브랜치}. PR 번호와 저장소를 확인하세요.
$(cat "$err_file")"
  fi
  die 1 "PR 정보를 조회하지 못했습니다.
$(cat "$err_file")"
fi

pr_number=""
pr_url=""
pr_state=""
is_draft=""
is_cross=""
author=""
base_branch=""
base_oid=""
head_branch=""
head_oid=""
mergeable=""
commits=""
pr_title=""
while IFS='=' read -r key value; do
  case "$key" in
    number)      pr_number="$value" ;;
    url)         pr_url="$value" ;;
    state)       pr_state="$value" ;;
    draft)       is_draft="$value" ;;
    cross)       is_cross="$value" ;;
    author)      author="$value" ;;
    base_branch) base_branch="$value" ;;
    base_oid)    base_oid="$value" ;;
    head_branch) head_branch="$value" ;;
    head_oid)    head_oid="$value" ;;
    mergeable)   mergeable="$value" ;;
    commits)     commits="$value" ;;
    title)       pr_title="$value" ;;
  esac
done <<< "$pr_info"

url_pattern='^https?://([^/]+)/([^/]+/[^/]+)/pull/[0-9]+'
[[ "$pr_url" =~ $url_pattern ]] || die 1 "PR 주소에서 저장소를 확인하지 못했습니다: $pr_url"
host="${BASH_REMATCH[1]}"
repo_name="${BASH_REMATCH[2]}"
repo_ref="$host/$repo_name"

log "PR #$pr_number: $pr_title ($head_branch → $base_branch)"
case "$pr_state" in
  MERGED|CLOSED) warn "이미 병합되었거나 닫힌 PR입니다(상태: $pr_state). 계속 리뷰할지 사용자에게 확인하세요." ;;
esac
[ "$is_draft" != true ] || warn "초안(draft) PR입니다. 리뷰 결과에 초안이라는 사실을 적으세요."
[ "$mergeable" != CONFLICTING ] || warn "base 브랜치와 충돌하는 PR입니다. 리뷰 결과에 병합 상태를 적으세요."

pr_path="$work_dir/pr.md"
gh pr view "$pr_number" -R "$repo_ref" --json title,url,author,headRefName,baseRefName,state,isDraft,body,commits --jq '
  "# \(.title)\n\n| 항목 | 내용 |\n|---|---|\n| PR | \(.url) |\n| 작성자 | \(.author.login // "ghost") |\n" +
  "| 브랜치 | \(.headRefName) → \(.baseRefName) |\n| 상태 | \(.state)\(if .isDraft then " (초안)" else "" end) |\n\n" +
  "## 설명\n\n\(if (.body // "") == "" then "(설명 없음)" else .body end)\n\n" +
  "## 커밋 (\(.commits | length)개)\n\n" + ([.commits[] | "- \(.oid[0:7]) \(.messageHeadline)"] | join("\n"))' \
  > "$pr_path" 2>"$err_file" || warn "PR 설명을 저장하지 못했습니다: $(head -n 1 "$err_file")"

# ---------------------------------------------------------------------------
# 로컬 저장소와 PR 커밋
# ---------------------------------------------------------------------------

host_lower="$(lowercase "$host")"
repo_lower="$(lowercase "$repo_name")"

# 원격 저장소($1)의 주소가 PR의 base 저장소를 가리키는지 확인한다.
remote_matches() {
  local url
  url="$(git remote get-url "$1" 2>/dev/null || true)"
  url="$(lowercase "${url%/}")"
  url="${url%.git}"
  case "$url" in
    *"$host_lower"[/:]"$repo_lower") return 0 ;;
  esac
  return 1
}

in_repo=false
remote=""
local_code=false
merge_base=""
worktree_is_head=false

if [ "$(git rev-parse --is-inside-work-tree 2>/dev/null || true)" = true ]; then
  in_repo=true
  if [ -n "$remote_arg" ]; then
    git remote get-url "$remote_arg" >/dev/null 2>&1 || die 2 "원격 저장소를 찾을 수 없습니다: '$remote_arg'"
    remote_matches "$remote_arg" || warn "지정한 원격 저장소가 PR의 base 저장소($repo_name)를 가리키지 않는 것 같습니다: $remote_arg"
    remote="$remote_arg"
  else
    for candidate in $(git remote); do
      if remote_matches "$candidate"; then
        remote="$candidate"
        break
      fi
    done
  fi
fi

if [ "$in_repo" = false ]; then
  warn "Git 저장소 밖에서 실행했으므로 GitHub에서 조회한 내용만 사용합니다."
elif [ -z "$remote" ]; then
  warn "PR의 base 저장소($repo_name)를 가리키는 원격 저장소를 찾지 못해 GitHub에서 조회한 내용만 사용합니다. 원격 저장소가 있다면 --remote로 지정하세요."
else
  if [ "$no_fetch" = false ]; then
    log "PR 커밋을 가져옵니다: $remote (refs/pull/$pr_number/head, $base_branch)"
    if ! fetch_output="$(git fetch --quiet --no-tags "$remote" \
      "+refs/heads/$base_branch:refs/remotes/$remote/$base_branch" "refs/pull/$pr_number/head" 2>&1)"; then
      die 5 "PR 커밋을 fetch하지 못했습니다. 네트워크 상태와 원격 저장소 이름을 확인하세요: $remote
$fetch_output"
    fi
  fi
  if git cat-file -e "$head_oid^{commit}" 2>/dev/null && git cat-file -e "$base_oid^{commit}" 2>/dev/null; then
    local_code=true
    merge_base="$(git merge-base "$base_oid" "$head_oid" 2>/dev/null || true)"
    if [ "$(git rev-parse HEAD 2>/dev/null || true)" = "$head_oid" ] \
      && [ -z "$(git status --porcelain --untracked-files=no)" ]; then
      worktree_is_head=true
    fi
  elif [ "$no_fetch" = true ]; then
    warn "로컬 저장소에 PR 커밋이 없어 GitHub에서 조회한 내용만 사용합니다. --no-fetch 없이 실행하면 PR 커밋을 가져옵니다."
  else
    die 5 "PR 커밋을 fetch했지만 head 커밋을 찾을 수 없습니다: $head_oid"
  fi

  current_branch="$(git symbolic-ref --quiet --short HEAD || true)"
  if [ "$current_branch" = "$head_branch" ] && [ "$worktree_is_head" = false ]; then
    warn "현재 브랜치($current_branch)가 PR head 커밋과 다르거나 커밋하지 않은 변경이 있습니다. 로컬에만 있는 변경은 리뷰 대상이 아니므로 사용자에게 알리세요."
  fi
fi

# ---------------------------------------------------------------------------
# 변경 내용
# ---------------------------------------------------------------------------

diff_path="$work_dir/pr.diff"
if ! gh pr diff "$pr_number" -R "$repo_ref" --color=never > "$diff_path" 2>"$err_file"; then
  if [ "$local_code" = true ]; then
    warn "gh pr diff로 diff를 조회하지 못해 로컬 PR 커밋으로 diff를 만듭니다: $(head -n 1 "$err_file")"
    git -c core.quotePath=false diff --no-color -M --src-prefix=a/ --dst-prefix=b/ \
      "$base_oid...$head_oid" > "$diff_path"
  else
    die 7 "PR diff를 조회하지 못했습니다. diff가 너무 크면 로컬 저장소에서 PR 커밋을 가져와 다시 실행하세요.
$(cat "$err_file")"
  fi
fi

since_commit=""
since_diff_path=""
if [ -n "$since_arg" ]; then
  [ "$local_code" = true ] || die 6 "--since를 사용하려면 로컬 저장소에 PR 커밋이 있어야 합니다. PR의 base 저장소를 가리키는 원격 저장소가 있는 Git 저장소 안에서 실행하세요."
  since_commit="$(git rev-parse --verify --quiet "$since_arg^{commit}" || true)"
  [ -n "$since_commit" ] || die 6 "재리뷰 기준 커밋을 찾을 수 없습니다: $since_arg. head 브랜치를 rebase했다면 PR 전체를 다시 리뷰하세요."
  git merge-base --is-ancestor "$since_commit" "$head_oid" \
    || die 6 "재리뷰 기준 커밋이 PR head 커밋의 이전 커밋이 아닙니다: $since_arg. head 브랜치를 rebase했다면 PR 전체를 다시 리뷰하세요."
  [ "$since_commit" != "$head_oid" ] || die 3 "재리뷰 기준 커밋 이후에 추가된 커밋이 없습니다: $since_arg"
  since_diff_path="$work_dir/since.diff"
  git -c core.quotePath=false diff --no-color -M --src-prefix=a/ --dst-prefix=b/ \
    "$since_commit" "$head_oid" > "$since_diff_path"
  log "재리뷰 범위: $(git rev-parse --short "$since_commit")..$(git rev-parse --short "$head_oid") ($(git rev-list --count "$since_commit..$head_oid")개 커밋)"
fi

files_path="$work_dir/files.tsv"
stats_path="$work_dir/stats.tsv"
MODE=files STATS_OUT="$stats_path" LC_ALL=C awk "$AWK_LIB
$AWK_ANALYZE" "$diff_path" > "$files_path"

changed_files="$(awk 'END { print NR }' "$files_path")"
[ "$changed_files" -gt 0 ] || die 3 "PR에 리뷰할 변경 사항이 없습니다: $pr_url"
added_lines="$(cut -f1 "$stats_path")"
deleted_lines="$(cut -f2 "$stats_path")"
test_files="$(awk -F'\t' '$1 != "D" && $2 == "test" { n++ } END { print n + 0 }' "$files_path")"
generated_files="$(awk -F'\t' '$2 == "generated" { n++ } END { print n + 0 }' "$files_path")"

# 추가한 줄 검사: 충돌 표시, 민감 정보, 디버그 출력, TODO, 줄 끝 공백
value_char="[^\"'[:space:]]"
secret_pattern="(password|passwd|secret|api[_-]?key|access[_-]?key|access[_-]?token|private[_-]?key|client[_-]?secret)[\"']?[[:space:]]*[:=][[:space:]]*[\"'][^\"'[:space:]\$<]$value_char$value_char$value_char$value_char$value_char$value_char$value_char$value_char*[\"']"
findings_path="$work_dir/findings.txt"
MODE=findings SECRET_PATTERN="$secret_pattern" LC_ALL=C awk "$AWK_LIB
$AWK_ANALYZE" "${since_diff_path:-$diff_path}" > "$findings_path"
auto_findings="$(awk 'END { print NR }' "$findings_path")"

# ---------------------------------------------------------------------------
# 연결된 이슈와 설계 문서
# ---------------------------------------------------------------------------

# 이슈 번호는 PR에 연결된 이슈(같은 저장소), head 브랜치 이름, 커밋 메시지의 Refs 푸터 순서로 찾는다.
issue_url_prefix="$(lowercase "https://$host/$repo_name/issues/")"
pr_refs="$(gh pr view "$pr_number" -R "$repo_ref" --json closingIssuesReferences,commits --jq "
  (.closingIssuesReferences[] | select((.url // \"\") | ascii_downcase | startswith(\"$issue_url_prefix\")) | \"closing \(.number)\"),
  (.commits[].messageBody | scan(\"(?m)^Refs: #([0-9]+)\") | \"refs \(.[0])\")" 2>"$err_file")" \
  || warn "PR에 연결된 이슈를 조회하지 못했습니다: $(head -n 1 "$err_file")"
branch_issue=""
branch_pattern='^[a-z]+/([0-9]+)-'
if [[ "$head_branch" =~ $branch_pattern ]]; then
  branch_issue="${BASH_REMATCH[1]}"
fi
issue_numbers="$({
  awk '$1 == "closing" { print $2 }' <<< "$pr_refs"
  printf '%s\n' "$branch_issue"
  awk '$1 == "refs" { print $2 }' <<< "$pr_refs"
} | awk 'NF && !seen[$0]++')"

issues=""
issues_path="$work_dir/issues.md"
: > "$issues_path"
issue_total=0
while IFS= read -r number; do
  [ -n "$number" ] || continue
  issue_total=$((issue_total + 1))
  if [ "$issue_total" -gt "$MAX_ISSUES" ]; then
    warn "연결된 이슈가 ${MAX_ISSUES}개를 넘어 나머지 이슈는 조회하지 않았습니다."
    break
  fi
  if gh issue view "$number" -R "$repo_ref" --json number,title,state,body \
    --jq '"## #\(.number) \(.title) (\(.state))\n\n\(if (.body // "") == "" then "(본문 없음)" else .body end)\n"' \
    >> "$issues_path" 2>"$err_file"; then
    issues="${issues:+$issues,}#$number"
  else
    warn "이슈 #$number를 조회하지 못했습니다: $(head -n 1 "$err_file")"
  fi
done <<< "$issue_numbers"

# 설계 문서는 PR head 커밋의 docs/<YYMMDD>/ 아래에서 관련 이슈가 같은 문서를 찾는다. (리뷰 보고서 제외)
doc_path=""
doc_file=""
if [ -n "$doc_arg" ]; then
  if [ -f "$doc_arg" ]; then
    doc_path="$doc_arg"
    doc_file="$(absolute_path "$doc_arg")"
  elif [ "$local_code" = true ] && git cat-file -e "$head_oid:$doc_arg" 2>/dev/null; then
    doc_path="$doc_arg"
    doc_file="$work_dir/design-doc.md"
    git show "$head_oid:$doc_arg" > "$doc_file"
  else
    die 2 "설계 문서를 찾을 수 없습니다: $doc_arg"
  fi
elif [ "$local_code" = true ] && [ -n "$issue_numbers" ]; then
  matches="$(while IFS= read -r number; do
      [ -n "$number" ] || continue
      git -c core.quotePath=false grep -l -E "^\| *관련 이슈 *\| *#$number *\|" "$head_oid" -- ':(glob)docs/*/*.md' 2>/dev/null || true
    done <<< "$issue_numbers" \
    | LC_ALL=C sed "s#^$head_oid:##" \
    | { grep -vE -- '-review(-[0-9]+)?\.md$' || true; } \
    | LC_ALL=C sort -u)"
  match_count="$(line_count "$matches")"
  if [ "$match_count" -eq 1 ]; then
    doc_path="$matches"
    doc_file="$work_dir/design-doc.md"
    git show "$head_oid:$doc_path" > "$doc_file"
    log "연결된 이슈와 관련 이슈가 같은 설계 문서를 찾았습니다: $doc_path"
  elif [ "$match_count" -gt 1 ]; then
    warn "연결된 이슈와 관련 이슈가 같은 설계 문서가 여러 개입니다. 함께 확인할 문서를 사용자에게 확인하고 --doc으로 지정하세요."
    printf '%s\n' "$matches" | LC_ALL=C sed 's/^/    /' >&2
  fi
fi

# ---------------------------------------------------------------------------
# 기존 리뷰와 코멘트
# ---------------------------------------------------------------------------

me="$(gh api --hostname "$host" user --jq .login 2>"$err_file" || true)"
[ -n "$me" ] || warn "현재 GitHub 사용자를 확인하지 못했습니다: $(head -n 1 "$err_file")"

review_meta="$(gh api --hostname "$host" --paginate "repos/$repo_name/pulls/$pr_number/reviews" \
  --jq '.[] | [(.user.login // ""), .state, (.commit_id // "")] | @tsv' 2>"$err_file")" \
  || warn "기존 리뷰를 조회하지 못했습니다: $(head -n 1 "$err_file")"
reviews="$(line_count "$review_meta")"
last_review_commit=""
if [ -n "$me" ] && [ -n "$review_meta" ]; then
  last_review_commit="$(awk -F'\t' -v me="$me" '$1 == me && $2 != "PENDING" && $3 != "" { commit = $3 } END { print commit }' <<< "$review_meta")"
fi

review_comments="$(gh api --hostname "$host" --paginate "repos/$repo_name/pulls/$pr_number/comments" --jq 'length' 2>"$err_file" \
  | awk '{ n += $1 } END { print n + 0 }')" || review_comments=0
comments="$(gh pr view "$pr_number" -R "$repo_ref" --json comments --jq '.comments | length' 2>"$err_file" || printf '0')"

discussion_path="$work_dir/discussion.md"
{
  printf '# PR #%s 기존 리뷰와 코멘트\n\n' "$pr_number"
  printf '## 리뷰 (%s개)\n\n' "$reviews"
  gh api --hostname "$host" --paginate "repos/$repo_name/pulls/$pr_number/reviews" --jq '.[] |
    "### \(.user.login // "ghost") - \(.state) (\(.submitted_at // "-"), 커밋 \((.commit_id // "")[0:7]))\n\n" +
    "\(if (.body // "") == "" then "(본문 없음)" else .body end)\n"' 2>"$err_file" || true
  printf '## 코드 줄 코멘트 (%s개)\n\n' "$review_comments"
  gh api --hostname "$host" --paginate "repos/$repo_name/pulls/$pr_number/comments" --jq '.[] |
    "### \(.path):\(.line // .original_line // "-")\(if .line == null then " (outdated)" else "" end)" +
    " - \(.user.login // "ghost") (\(.created_at))\n\n\(.body)\n"' 2>"$err_file" || true
  printf '## 일반 코멘트 (%s개)\n\n' "$comments"
  gh pr view "$pr_number" -R "$repo_ref" --json comments \
    --jq '.comments[] | "### \(.author.login // "ghost") (\(.createdAt))\n\n\(.body)\n"' 2>"$err_file" || true
} > "$discussion_path"

# ---------------------------------------------------------------------------
# CI 결과
# ---------------------------------------------------------------------------

# gh pr checks는 실패한 검사가 있으면 1, 진행 중인 검사가 있으면 8로 종료하므로 출력 내용으로 판단한다.
checks_path="$work_dir/checks.tsv"
checks_status=0
gh pr checks "$pr_number" -R "$repo_ref" --json bucket,name,link \
  --jq '.[] | [.bucket, .name, .link] | @tsv' > "$checks_path" 2>"$err_file" || checks_status=$?

checks_total=""
checks_passed=""
checks_failed=""
checks_pending=""
if [ -s "$checks_path" ]; then
  checks_total="$(awk 'END { print NR }' "$checks_path")"
  checks_passed="$(awk -F'\t' '$1 == "pass" { n++ } END { print n + 0 }' "$checks_path")"
  checks_failed="$(awk -F'\t' '$1 == "fail" || $1 == "cancel" { n++ } END { print n + 0 }' "$checks_path")"
  checks_pending="$(awk -F'\t' '$1 == "pending" { n++ } END { print n + 0 }' "$checks_path")"
elif grep -qi 'no checks reported' "$err_file"; then
  checks_total=0
  checks_passed=0
  checks_failed=0
  checks_pending=0
elif [ "$checks_status" -ne 0 ]; then
  warn "CI 결과를 조회하지 못했습니다: $(head -n 1 "$err_file")"
fi

# ---------------------------------------------------------------------------
# 결과 출력
# ---------------------------------------------------------------------------

log "변경 파일 (${changed_files}개, +$added_lines / -$deleted_lines):"
awk -F'\t' '{ printf "    %-4s %s%s\n", $1, $3, ($2 == "generated" ? " (자동 생성 파일)" : "") }' "$files_path" | head -n 50 >&2
if [ "$changed_files" -gt 50 ]; then
  printf '    ... 외 %d개 (%s)\n' "$((changed_files - 50))" "$files_path" >&2
fi
if [ -n "$issues" ]; then
  log "연결된 이슈: $issues"
fi
if [ -n "$checks_total" ]; then
  log "CI 검사: 전체 $checks_total, 성공 $checks_passed, 실패 $checks_failed, 진행 중 $checks_pending"
  awk -F'\t' '$1 == "fail" || $1 == "cancel" { printf "    실패: %s %s\n", $2, $3 }' "$checks_path" >&2
fi
if [ -n "$last_review_commit" ]; then
  log "이전에 등록한 리뷰가 있습니다. 재리뷰라면 --since $last_review_commit 옵션으로 이후 변경을 확인하세요."
fi
if [ "$auto_findings" -eq 0 ]; then
  log "자동 검사에서 찾은 항목이 없습니다."
else
  log "자동 검사 항목 (${auto_findings}개, 지적 후보):"
  head -n 30 "$findings_path" | awk -F'|' '{ printf "    [%s] %s - %s: %s\n", $1, $2, $3, $4 }' >&2
  if [ "$auto_findings" -gt 30 ]; then
    printf '    ... 외 %d개 (%s)\n' "$((auto_findings - 30))" "$findings_path" >&2
  fi
fi

printf 'RESULT=collected\n'
printf 'REPO=%s\n' "$repo_name"
printf 'PR_NUMBER=%s\n' "$pr_number"
printf 'PR_URL=%s\n' "$pr_url"
printf 'PR_TITLE=%s\n' "$pr_title"
printf 'PR_STATE=%s\n' "$pr_state"
printf 'IS_DRAFT=%s\n' "$is_draft"
printf 'IS_CROSS_REPOSITORY=%s\n' "$is_cross"
printf 'AUTHOR=%s\n' "$author"
printf 'BASE_BRANCH=%s\n' "$base_branch"
printf 'BASE_COMMIT=%s\n' "$base_oid"
printf 'HEAD_BRANCH=%s\n' "$head_branch"
printf 'HEAD_COMMIT=%s\n' "$head_oid"
printf 'MERGE_BASE=%s\n' "$merge_base"
printf 'MERGEABLE=%s\n' "$mergeable"
printf 'COMMITS=%s\n' "$commits"
printf 'CHANGED_FILES=%s\n' "$changed_files"
printf 'ADDED_LINES=%s\n' "$added_lines"
printf 'DELETED_LINES=%s\n' "$deleted_lines"
printf 'TEST_FILES_CHANGED=%s\n' "$test_files"
printf 'GENERATED_FILES=%s\n' "$generated_files"
printf 'LOCAL_CODE=%s\n' "$local_code"
printf 'REMOTE=%s\n' "$remote"
printf 'WORKTREE_IS_HEAD=%s\n' "$worktree_is_head"
printf 'SINCE=%s\n' "$since_commit"
printf 'ISSUES=%s\n' "$issues"
printf 'DOC_PATH=%s\n' "$doc_path"
printf 'DOC_FILE=%s\n' "$doc_file"
printf 'CHECKS_TOTAL=%s\n' "$checks_total"
printf 'CHECKS_PASSED=%s\n' "$checks_passed"
printf 'CHECKS_FAILED=%s\n' "$checks_failed"
printf 'CHECKS_PENDING=%s\n' "$checks_pending"
printf 'REVIEWS=%s\n' "$reviews"
printf 'REVIEW_COMMENTS=%s\n' "$review_comments"
printf 'COMMENTS=%s\n' "$comments"
printf 'LAST_REVIEW_COMMIT=%s\n' "$last_review_commit"
printf 'AUTO_FINDINGS=%s\n' "$auto_findings"
printf 'WORK_DIR=%s\n' "$work_dir"
printf 'PR_PATH=%s\n' "$pr_path"
printf 'DIFF_PATH=%s\n' "$diff_path"
printf 'SINCE_DIFF_PATH=%s\n' "$since_diff_path"
printf 'FILES_PATH=%s\n' "$files_path"
printf 'ISSUES_PATH=%s\n' "$issues_path"
printf 'DISCUSSION_PATH=%s\n' "$discussion_path"
printf 'CHECKS_PATH=%s\n' "$checks_path"
printf 'FINDINGS_PATH=%s\n' "$findings_path"
