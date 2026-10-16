#!/usr/bin/env bash
#
# git-pr-code-review 스킬 규칙에 따라 리뷰 결과를 GitHub PR에 리뷰 하나로 등록한다.
#
# 요약 본문과 인라인 코멘트를 리뷰 하나에 담아 한 번에 등록한다. 등록하기 전에 다음을 확인한다.
#   - 리뷰한 커밋 이후에 PR에 새 커밋이 push되지 않았는지
#   - 자신의 PR에 승인이나 변경 요청을 등록하려는 것은 아닌지
#   - 인라인 코멘트가 diff에 포함된 줄을 가리키는지
#   - 본문에 민감 정보로 의심되는 값이 없는지
#   - 같은 커밋에 이미 등록한 리뷰가 없는지
#
# 사용법:
#   post-review.sh <PR> --commit <리뷰 기준 커밋> --body-file <요약 본문 파일> [옵션]
#
# 인라인 코멘트 파일 형식 (--comments-file):
#   @comment <파일 경로>:<줄>[-<끝 줄>] [LEFT|RIGHT]
#   <코멘트 본문, 여러 줄 가능>
#
#   - 다음 @comment 줄 전까지가 코멘트 본문이다.
#   - 위치 뒤의 LEFT는 삭제한 줄(base 기준 줄 번호), RIGHT는 추가한 줄과 문맥 줄(head 기준 줄 번호)이다. 생략하면 RIGHT다.
#
# 결과 (표준 출력, key=value 형식):
#   RESULT=posted | dry-run
#   REPO, PR_NUMBER, COMMIT, EVENT, INLINE_COMMENTS, REVIEW_ID, REVIEW_URL, PAYLOAD_PATH
#
# 종료 코드:
#   0  성공
#   1  gh 명령 실패 또는 리뷰 등록 실패
#   2  인자 오류 (인라인 코멘트 파일 형식 오류 포함)
#   3  PR을 찾을 수 없음
#   4  gh 미설치 또는 미인증
#   5  리뷰 기준 커밋 이후에 새 커밋이 push됨
#   6  자신의 PR에 승인이나 변경 요청을 등록하려고 함
#   7  같은 커밋에 이미 등록한 리뷰가 있음
#   8  diff에 포함되지 않은 줄을 가리키는 인라인 코멘트가 있음
#   9  민감 정보로 의심되는 값이 본문에 있음
#
# 요구 사항: bash 3.2 이상, GitHub CLI(gh) 2.72 이상, awk

set -euo pipefail

# gh가 입력을 기다리거나 업데이트 안내를 출력하지 않도록 한다.
export GH_PROMPT_DISABLED=1
export GH_NO_UPDATE_NOTIFIER=1

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
사용법: post-review.sh <PR> --commit <리뷰 기준 커밋> --body-file <요약 본문 파일> [옵션]

<PR>은 PR 번호나 URL이다.

옵션:
  --commit <커밋>            리뷰한 PR head 커밋의 전체 해시 (pr-context.sh의 HEAD_COMMIT). 필수 옵션이다.
  --body-file <파일>         리뷰 요약 본문 파일. 필수 옵션이다.
  --comments-file <파일>     인라인 코멘트 파일
  --event <종류>             comment(기본), approve, request-changes. approve와 request-changes는 사용자 요청이 필요하다.
  --repo <owner/repo>        PR이 있는 저장소 (기본: 현재 디렉터리의 저장소)
  --allow-duplicate          같은 커밋에 이미 등록한 리뷰가 있어도 등록한다. 사용자 승인이 필요하다.
  --dry-run                  검증과 미리보기만 수행하고 리뷰를 등록하지 않는다.
  -h, --help                 도움말을 출력한다

인라인 코멘트 파일 형식:
  @comment src/main/java/com/example/auth/KakaoLoginService.java:42
  **[중간]** 카카오 API 호출이 실패해도 예외를 처리하지 않습니다.

  제안: 외부 API 실패를 SocialLoginException으로 감싸 주세요.

  @comment src/main/java/com/example/auth/KakaoLoginService.java:50-55
  여러 줄에 걸친 코멘트는 <시작 줄>-<끝 줄>로 지정한다.

  @comment src/main/java/com/example/auth/LegacyLogin.java:12 LEFT
  삭제한 줄에는 LEFT를 붙이고 base 기준 줄 번호를 쓴다.
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
commit=""
body_arg=""
comments_arg=""
event_arg="comment"
repo_arg=""
allow_duplicate=false
dry_run=false

while [ $# -gt 0 ]; do
  case "$1" in
    --commit)          need_value "$1" $# "${2:-}"; commit="$2"; shift 2 ;;
    --body-file)       need_value "$1" $# "${2:-}"; body_arg="$2"; shift 2 ;;
    --comments-file)   need_value "$1" $# "${2:-}"; comments_arg="$2"; shift 2 ;;
    --event)           need_value "$1" $# "${2:-}"; event_arg="$2"; shift 2 ;;
    --repo)            need_value "$1" $# "${2:-}"; repo_arg="$2"; shift 2 ;;
    --allow-duplicate) allow_duplicate=true; shift ;;
    --dry-run)         dry_run=true; shift ;;
    -h|--help)         usage; exit 0 ;;
    -*)                die 2 "알 수 없는 옵션입니다: $1" ;;
    *)
      [ -z "$pr_arg" ] || die 2 "PR은 하나만 지정할 수 있습니다: $1"
      pr_arg="$1"
      shift
      ;;
  esac
done

[ -n "$pr_arg" ] || { usage >&2; die 2 "리뷰를 등록할 PR을 입력해야 합니다."; }
[ -n "$commit" ] || die 2 "리뷰 기준 커밋을 --commit 옵션으로 입력해야 합니다."
[[ "$commit" =~ ^[0-9a-f]{40}$ ]] || die 2 "--commit에는 커밋의 전체 해시(40자)를 입력해야 합니다: '$commit'"
[ -n "$body_arg" ] || die 2 "요약 본문 파일을 --body-file 옵션으로 입력해야 합니다."
[ -f "$body_arg" ] || die 2 "요약 본문 파일을 찾을 수 없습니다: $body_arg"
if [ -n "$comments_arg" ]; then
  [ -f "$comments_arg" ] || die 2 "인라인 코멘트 파일을 찾을 수 없습니다: $comments_arg"
fi

case "$event_arg" in
  comment)         event=COMMENT ;;
  approve)         event=APPROVE ;;
  request-changes) event=REQUEST_CHANGES ;;
  *) die 2 "--event는 comment, approve, request-changes 중 하나여야 합니다: '$event_arg'" ;;
esac

if [ -n "$repo_arg" ]; then
  repo_pattern='^([A-Za-z0-9.-]+/)?[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$'
  [[ "$repo_arg" =~ $repo_pattern ]] || die 2 "저장소는 owner/repo 형식으로 입력해야 합니다: '$repo_arg'"
  case "$pr_arg" in
    http://*|https://*) die 2 "PR URL을 사용할 때는 --repo 옵션을 함께 지정하지 않습니다." ;;
  esac
fi

tmp_root="${TMPDIR:-/tmp}"
work_dir="$(mktemp -d "${tmp_root%/}/git-pr-code-review-post.XXXXXX")" || die 1 "작업 디렉터리를 만들지 못했습니다."
err_file="$work_dir/gh-error.log"
comments_dir="$work_dir/comments"
meta_path="$comments_dir/meta.tsv"
body_path="$work_dir/body.md"
payload_path="$work_dir/payload.json"
mkdir -p "$comments_dir"
: > "$meta_path"

# ---------------------------------------------------------------------------
# 본문과 인라인 코멘트 해석
# ---------------------------------------------------------------------------

# 줄 끝의 CR과 앞뒤 빈 줄을 지운다.
read -r -d '' AWK_TRIM <<'AWK' || true
{ sub(/\r$/, ""); lines[NR] = $0 }
END {
  first = 1
  while (first <= NR && lines[first] ~ /^[ \t]*$/) first++
  last = NR
  while (last >= first && lines[last] ~ /^[ \t]*$/) last--
  for (i = first; i <= last; i++) print lines[i]
}
AWK

LC_ALL=C awk "$AWK_TRIM" "$body_arg" > "$body_path"
[ -s "$body_path" ] || die 2 "요약 본문이 비어 있습니다: $body_arg"

# 인라인 코멘트 파일을 comments/meta.tsv("번호<TAB>경로<TAB>시작 줄<TAB>끝 줄<TAB>side")와
# comments/comment-<번호>.md(본문)로 나눈다. 시작 줄이 없으면 "-"로 기록한다.
read -r -d '' AWK_COMMENTS <<'AWK' || true
BEGIN {
  DIR = ENVIRON["DIR"]
  ERRORS = ENVIRON["ERRORS"]
}
function fail(line_number, message) {
  printf "    %d번째 줄: %s\n", line_number, message > ERRORS
  errors++
}
function finish(    i, first, last, body_file) {
  if (count == 0) return
  first = 1
  while (first <= body_lines && lines[first] ~ /^[ \t]*$/) first++
  last = body_lines
  while (last >= first && lines[last] ~ /^[ \t]*$/) last--
  if (first > last) fail(header_line, "인라인 코멘트 본문이 비어 있습니다.")
  body_file = DIR "/comment-" count ".md"
  printf "" > body_file
  for (i = first; i <= last; i++) print lines[i] > body_file
  close(body_file)
  printf "%d\t%s\t%s\t%s\t%s\n", count, comment_path, start_line, end_line, side > (DIR "/meta.tsv")
  body_lines = 0
}
{ sub(/\r$/, "") }
/^@comment([ \t]|$)/ {
  finish()
  count++
  header_line = NR
  spec = $0
  sub(/^@comment[ \t]*/, "", spec)
  sub(/[ \t]+$/, "", spec)
  side = "RIGHT"
  if (spec ~ /[ \t](LEFT|RIGHT)$/) {
    side = substr(spec, length(spec) - 4)
    sub(/^[ \t]/, "", side)
    sub(/[ \t]+(LEFT|RIGHT)$/, "", spec)
  }
  position = 0
  for (i = length(spec); i > 0; i--) {
    if (substr(spec, i, 1) == ":") { position = i; break }
  }
  comment_path = ""
  start_line = "-"
  end_line = "0"
  if (position <= 1) {
    fail(NR, "위치는 @comment <파일 경로>:<줄> 형식이어야 합니다: " $0)
    next
  }
  comment_path = substr(spec, 1, position - 1)
  sub(/^\.\//, "", comment_path)
  range = substr(spec, position + 1)
  if (range ~ /^[1-9][0-9]*$/) {
    end_line = range
  } else if (range ~ /^[1-9][0-9]*-[1-9][0-9]*$/) {
    start_line = range
    sub(/-.*/, "", start_line)
    end_line = range
    sub(/.*-/, "", end_line)
    if (start_line + 0 >= end_line + 0) fail(NR, "시작 줄은 끝 줄보다 작아야 합니다: " range)
  } else {
    fail(NR, "줄 번호는 <줄> 또는 <시작 줄>-<끝 줄> 형식이어야 합니다: " range)
  }
  next
}
count == 0 {
  if ($0 !~ /^[ \t]*$/) fail(NR, "첫 번째 @comment 줄보다 앞에 내용이 있습니다.")
  next
}
{ lines[++body_lines] = $0 }
END {
  finish()
  if (errors > 0) exit 3
  print count + 0
}
AWK

comment_count=0
if [ -n "$comments_arg" ]; then
  if ! comment_count="$(DIR="$comments_dir" ERRORS="$err_file" LC_ALL=C awk "$AWK_COMMENTS" "$comments_arg")"; then
    die 2 "인라인 코멘트 파일 형식이 올바르지 않습니다: $comments_arg
$(cat "$err_file")"
  fi
fi

# 본문에 민감 정보로 의심되는 값이 있는지 검사한다.
value_char="[^\"'[:space:]]"
secret_pattern="(password|passwd|secret|api[_-]?key|access[_-]?key|access[_-]?token|private[_-]?key|client[_-]?secret)[\"']?[[:space:]]*[:=][[:space:]]*[\"'][^\"'[:space:]\$<]$value_char$value_char$value_char$value_char$value_char$value_char$value_char$value_char*[\"']"
find_secrets() {
  SECRET_PATTERN="$secret_pattern" LABEL="$1" LC_ALL=C awk \
    'tolower($0) ~ ENVIRON["SECRET_PATTERN"] { printf "    %s %d번째 줄\n", ENVIRON["LABEL"], FNR }' "$2"
}
sensitive="$(
  find_secrets "요약 본문" "$body_path"
  while IFS="$(printf '\t')" read -r index _; do
    [ -n "$index" ] || continue
    find_secrets "인라인 코멘트 $index" "$comments_dir/comment-$index.md"
  done < "$meta_path"
)"
if [ -n "$sensitive" ]; then
  die 9 "비밀번호나 키로 의심되는 값이 리뷰 본문에 있습니다. 값을 지우고 위치만 적으세요.
$sensitive"
fi

# ---------------------------------------------------------------------------
# GitHub CLI와 PR 확인
# ---------------------------------------------------------------------------

command -v gh >/dev/null 2>&1 || die 4 "GitHub CLI(gh)가 설치되어 있지 않습니다. 사용자에게 설치를 요청하세요."

if ! gh auth status >/dev/null 2>"$err_file"; then
  die 4 "GitHub CLI 인증이 필요합니다. 사용자에게 gh auth login 실행을 요청하세요.
$(cat "$err_file")"
fi

# shellcheck disable=SC2086
if ! pr_info="$(gh pr view "$pr_arg" ${repo_arg:+-R "$repo_arg"} --json number,url,state,headRefOid,author \
  --jq '"number=\(.number)", "url=\(.url)", "state=\(.state)", "head_oid=\(.headRefOid)", "author=\(.author.login // "")"' \
  2>"$err_file")"; then
  if grep -qiE 'no pull requests? found|could not resolve to a pull ?request|not found' "$err_file"; then
    die 3 "PR을 찾을 수 없습니다: $pr_arg. PR 번호와 저장소를 확인하세요.
$(cat "$err_file")"
  fi
  die 1 "PR 정보를 조회하지 못했습니다.
$(cat "$err_file")"
fi

pr_number=""
pr_url=""
pr_state=""
head_oid=""
author=""
while IFS='=' read -r key value; do
  case "$key" in
    number)   pr_number="$value" ;;
    url)      pr_url="$value" ;;
    state)    pr_state="$value" ;;
    head_oid) head_oid="$value" ;;
    author)   author="$value" ;;
  esac
done <<< "$pr_info"

url_pattern='^https?://([^/]+)/([^/]+/[^/]+)/pull/[0-9]+'
[[ "$pr_url" =~ $url_pattern ]] || die 1 "PR 주소에서 저장소를 확인하지 못했습니다: $pr_url"
host="${BASH_REMATCH[1]}"
repo_name="${BASH_REMATCH[2]}"
repo_ref="$host/$repo_name"

if [ "$head_oid" != "$commit" ]; then
  die 5 "리뷰한 커밋 이후에 PR에 새 커밋이 push되었습니다. (리뷰 기준: ${commit:0:7}, 현재 head: ${head_oid:0:7})
새 커밋을 사용자에게 알리고, 새 커밋까지 포함해 다시 리뷰할지 확인하세요."
fi
case "$pr_state" in
  MERGED|CLOSED) warn "이미 병합되었거나 닫힌 PR입니다(상태: $pr_state)." ;;
esac

me="$(gh api --hostname "$host" user --jq .login 2>"$err_file")" \
  || die 1 "현재 GitHub 사용자를 확인하지 못했습니다.
$(cat "$err_file")"
if [ "$event" != COMMENT ] && [ "$author" = "$me" ]; then
  die 6 "자신이 작성한 PR에는 승인이나 변경 요청을 등록할 수 없습니다. 코멘트(--event comment)로 등록할지 사용자에게 확인하세요."
fi

# ---------------------------------------------------------------------------
# 인라인 코멘트 위치 검사
# ---------------------------------------------------------------------------

# diff에서 코멘트를 달 수 있는 줄을 "side<TAB>경로<TAB>줄 번호<TAB>변경 구간 번호"로 출력한다.
# 추가한 줄과 문맥 줄은 RIGHT(head 기준), 삭제한 줄과 문맥 줄은 LEFT(base 기준)다.
read -r -d '' AWK_DIFF_LINES <<'AWK' || true
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
function clean_path(p) {
  sub(/\t$/, "", p)
  p = decode_path(p)
  if (p != "/dev/null") sub(/^[ab]\//, "", p)
  return p
}
function start_hunk() {
  in_header = 0
  hunk++
  if (match($0, /-[0-9]+/)) old_line = substr($0, RSTART + 1, RLENGTH - 1) + 0
  if (match($0, /\+[0-9]+/)) new_line = substr($0, RSTART + 1, RLENGTH - 1) + 0
}
/^diff --git / { in_header = 1; path = ""; old_path = ""; next }
in_header {
  if ($0 ~ /^--- /) old_path = clean_path(substr($0, 5))
  else if ($0 ~ /^\+\+\+ /) { path = clean_path(substr($0, 5)); if (path == "/dev/null") path = old_path }
  else if ($0 ~ /^@@ /) start_hunk()
  next
}
/^@@ / { start_hunk(); next }
/^\+/ { print "RIGHT\t" path "\t" new_line++ "\t" hunk; next }
/^-/ { print "LEFT\t" path "\t" old_line++ "\t" hunk; next }
/^ / { print "RIGHT\t" path "\t" new_line++ "\t" hunk; print "LEFT\t" path "\t" old_line++ "\t" hunk; next }
AWK

if [ "$comment_count" -gt 0 ]; then
  diff_path="$work_dir/pr.diff"
  valid_path="$work_dir/valid-lines.tsv"
  if gh pr diff "$pr_number" -R "$repo_ref" --color=never > "$diff_path" 2>"$err_file"; then
    LC_ALL=C awk "$AWK_DIFF_LINES" "$diff_path" > "$valid_path"
    invalid="$(LC_ALL=C awk -F'\t' '
      FILENAME == ARGV[1] { hunk[$1 SUBSEP $2 SUBSEP $3] = $4; next }
      {
        location = $2 ":" ($3 == "-" ? "" : $3 "-") $4 " " $5
        end_key = $5 SUBSEP $2 SUBSEP $4
        if (!(end_key in hunk)) {
          printf "    인라인 코멘트 %s (%s): diff에 포함되지 않은 줄입니다.\n", $1, location
        } else if ($3 != "-") {
          start_key = $5 SUBSEP $2 SUBSEP $3
          if (!(start_key in hunk)) printf "    인라인 코멘트 %s (%s): 시작 줄이 diff에 포함되지 않습니다.\n", $1, location
          else if (hunk[start_key] != hunk[end_key]) printf "    인라인 코멘트 %s (%s): 시작 줄과 끝 줄이 같은 변경 구간(hunk)에 있지 않습니다.\n", $1, location
        }
      }' "$valid_path" "$meta_path")"
    if [ -n "$invalid" ]; then
      die 8 "diff에 포함되지 않은 줄을 가리키는 인라인 코멘트가 있습니다. 경로, 줄 번호, side를 확인하고, diff 밖의 줄에 대한 지적 사항은 요약 본문으로 옮기세요.
$invalid"
    fi
  else
    warn "PR diff를 조회하지 못해 인라인 코멘트 위치를 미리 검사하지 않습니다. 위치가 잘못되면 GitHub이 리뷰 등록을 거부합니다: $(head -n 1 "$err_file")"
  fi
fi

# ---------------------------------------------------------------------------
# 중복 리뷰 확인
# ---------------------------------------------------------------------------

if ! existing="$(gh api --hostname "$host" --paginate "repos/$repo_name/pulls/$pr_number/reviews" \
  --jq ".[] | select(.user.login == \"$me\" and .commit_id == \"$commit\") | .html_url" 2>"$err_file")"; then
  die 1 "기존 리뷰를 조회하지 못했습니다.
$(cat "$err_file")"
fi
if [ -n "$existing" ] && [ "$allow_duplicate" = false ]; then
  die 7 "같은 커밋(${commit:0:7})에 이미 등록한 리뷰가 있습니다. 중복 등록인지 사용자에게 확인하고, 그래도 등록하려면 --allow-duplicate 옵션을 추가하세요.
$(printf '%s\n' "$existing" | LC_ALL=C sed 's/^/    /')"
fi

# ---------------------------------------------------------------------------
# 요청 본문(JSON) 생성
# ---------------------------------------------------------------------------

# 파일 내용(또는 표준 입력)을 JSON 문자열로 출력한다. 줄바꿈은 \n으로, 제어 문자는 \uXXXX로 바꾼다.
read -r -d '' AWK_JSON_STRING <<'AWK' || true
BEGIN {
  for (i = 1; i < 32; i++) control[sprintf("%c", i)] = sprintf("\\u%04x", i)
  control["\t"] = "\\t"
  printf "\""
}
{
  sub(/\r$/, "")
  if (NR > 1) printf "\\n"
  out = ""
  n = length($0)
  for (i = 1; i <= n; i++) {
    c = substr($0, i, 1)
    if (c == "\\") out = out "\\\\"
    else if (c == "\"") out = out "\\\""
    else if (c in control) out = out control[c]
    else out = out c
  }
  printf "%s", out
}
END { printf "\"" }
AWK

json_string() {
  LC_ALL=C awk "$AWK_JSON_STRING" "${1:--}"
}

{
  printf '{\n'
  printf '  "commit_id": "%s",\n' "$commit"
  printf '  "event": "%s",\n' "$event"
  printf '  "body": %s,\n' "$(json_string "$body_path")"
  printf '  "comments": ['
  separator=""
  while IFS="$(printf '\t')" read -r index path start_line end_line side; do
    [ -n "$index" ] || continue
    printf '%s\n    {"path": %s, ' "$separator" "$(printf '%s\n' "$path" | json_string)"
    if [ "$start_line" != "-" ]; then
      printf '"start_line": %s, "start_side": "%s", ' "$start_line" "$side"
    fi
    printf '"line": %s, "side": "%s", "body": %s}' "$end_line" "$side" "$(json_string "$comments_dir/comment-$index.md")"
    separator=","
  done < "$meta_path"
  [ -z "$separator" ] || printf '\n  '
  printf ']\n}\n'
} > "$payload_path"

if command -v jq >/dev/null 2>&1; then
  jq empty "$payload_path" 2>"$err_file" || die 1 "리뷰 요청 본문(JSON)을 만들지 못했습니다: $payload_path
$(cat "$err_file")"
fi

# ---------------------------------------------------------------------------
# 미리보기와 등록
# ---------------------------------------------------------------------------

visibility="$(gh repo view "$repo_ref" --json visibility --jq .visibility 2>/dev/null || true)"
[ "$visibility" != PUBLIC ] || warn "공개 저장소입니다. 리뷰 내용이 외부에 공개됩니다: $repo_name"

log "등록할 리뷰:"
{
  printf '    PR: %s\n' "$pr_url"
  printf '    기준 커밋: %s\n' "${commit:0:7}"
  printf '    이벤트: %s\n' "$event"
  printf '    인라인 코멘트: %s개\n' "$comment_count"
  printf '    ---------- 요약 본문 ----------\n'
  LC_ALL=C sed 's/^/    /' "$body_path"
  while IFS="$(printf '\t')" read -r index path start_line end_line side; do
    [ -n "$index" ] || continue
    if [ "$start_line" = "-" ]; then
      printf '    ---------- 인라인 코멘트 %s: %s:%s (%s) ----------\n' "$index" "$path" "$end_line" "$side"
    else
      printf '    ---------- 인라인 코멘트 %s: %s:%s-%s (%s) ----------\n' "$index" "$path" "$start_line" "$end_line" "$side"
    fi
    LC_ALL=C sed 's/^/    /' "$comments_dir/comment-$index.md"
  done < "$meta_path"
} >&2

print_result() {
  printf 'RESULT=%s\n' "$1"
  printf 'REPO=%s\n' "$repo_name"
  printf 'PR_NUMBER=%s\n' "$pr_number"
  printf 'COMMIT=%s\n' "$commit"
  printf 'EVENT=%s\n' "$event"
  printf 'INLINE_COMMENTS=%s\n' "$comment_count"
  printf 'REVIEW_ID=%s\n' "$2"
  printf 'REVIEW_URL=%s\n' "$3"
  printf 'PAYLOAD_PATH=%s\n' "$payload_path"
}

if [ "$dry_run" = true ]; then
  log "--dry-run으로 실행해 리뷰를 등록하지 않았습니다."
  print_result dry-run "" ""
  exit 0
fi

if ! response="$(gh api --hostname "$host" --method POST "repos/$repo_name/pulls/$pr_number/reviews" \
  --input "$payload_path" --jq '"\(.id) \(.html_url)"' 2>"$err_file")"; then
  hint="다시 시도하기 전에 리뷰가 등록되었는지 PR에서 확인하세요."
  if grep -q 'HTTP 422' "$err_file"; then
    hint="인라인 코멘트의 경로, 줄 번호, side가 diff에 포함되는지 확인하세요. $hint"
  elif grep -qE 'HTTP (403|404)' "$err_file"; then
    hint="리뷰를 등록할 권한이나 토큰 권한이 부족할 수 있습니다. $hint"
  fi
  die 1 "리뷰를 등록하지 못했습니다. $hint
$(cat "$err_file")"
fi

review_id="${response%% *}"
review_url="${response#* }"
log "리뷰를 등록했습니다: $review_url"
print_result posted "$review_id" "$review_url"
