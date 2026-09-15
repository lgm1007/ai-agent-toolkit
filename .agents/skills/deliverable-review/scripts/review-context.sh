#!/usr/bin/env bash
#
# deliverable-review 스킬 규칙에 따라 리뷰 대상(설계 문서 또는 코드 변경)의 리뷰 근거를 수집하고 자동 검사를 실행한다.
#
# 설계 문서는 docs-create 스킬의 check-doc.sh로 구조를 검사하고, 요구사항 ID가 작업 목록과 테스트 계획에 있는지 확인한다.
# 코드 변경은 기준 브랜치와 갈라진 지점부터 현재 작업 트리까지의 변경 목록과 diff를 만들고,
# 추가한 줄에서 충돌 표시, 민감 정보, 디버그 출력, TODO를 찾는다.
# 자동 검사 결과는 지적 후보이며, 에이전트가 실제 문제인지 확인한 뒤 보고서에 반영한다.
#
# 사용법:
#   review-context.sh doc <설계 문서 경로>
#   review-context.sh code [--base <브랜치>] [--doc <설계 문서 경로>] [--remote <이름>] [--no-fetch]
#
# 결과 (표준 출력, key=value 형식):
#   공통: RESULT=collected, TARGET_TYPE, AUTO_FINDINGS, FINDINGS_PATH
#   doc:  DOC_PATH, DOC_CHECK, DOC_ISSUES, DOC_STATUS, REQUIREMENTS, UNTRACED_TASKS, UNTRACED_TESTS, UNRESOLVED
#   code: BRANCH, BASE, MERGE_BASE, COMMITS, CHANGED_FILES, UNCOMMITTED_FILES, ADDED_LINES, DELETED_LINES,
#         TEST_FILES_CHANGED, DOC_PATH, REQUIREMENTS, DIFF_PATH
#
# 종료 코드:
#   0  수집 완료
#   1  저장소 상태 오류 또는 필요한 스크립트 없음
#   2  인자 오류
#   3  리뷰 대상 없음
#   4  기준 브랜치를 찾을 수 없거나 후보가 여러 개
#   5  원격 저장소 조회 또는 fetch 실패
#
# 요구 사항: bash 3.2 이상, git 2.23 이상, awk, docs-create 스킬의 scripts/check-doc.sh

set -euo pipefail

readonly BASE_CANDIDATES="develop dev development"

# 인증 정보가 없을 때 입력 대기로 멈추지 않고 바로 실패하도록 한다.
export GIT_TERMINAL_PROMPT=0

log()  { printf '[deliverable-review] %s\n' "$*" >&2; }
warn() { printf '[deliverable-review] 경고: %s\n' "$*" >&2; }
die() {
  local code="$1"
  shift
  printf '[deliverable-review] 오류: %s\n' "$*" >&2
  exit "$code"
}

usage() {
  cat <<'EOF'
사용법:
  review-context.sh doc <설계 문서 경로>
  review-context.sh code [옵션]

code 옵션:
  --base <브랜치>          기준 브랜치 (기본: develop, dev, development 자동 탐색)
  --doc <설계 문서 경로>   함께 리뷰할 설계 문서 (기본: 브랜치의 이슈 번호로 탐색)
  --remote <이름>          원격 저장소 이름 (기본: origin)
  --no-fetch               원격 저장소에 접속하지 않고 마지막으로 fetch한 기준 브랜치를 사용한다
  -h, --help               도움말을 출력한다
EOF
}

# ---------------------------------------------------------------------------
# 인자 해석
# ---------------------------------------------------------------------------

[ $# -gt 0 ] || { usage >&2; die 2 "리뷰 대상 유형(doc 또는 code)을 입력해야 합니다."; }
case "$1" in
  -h|--help) usage; exit 0 ;;
esac

target_type="$1"
shift
doc_arg=""
base=""
remote="origin"
no_fetch=false

need_value() {
  [ "$2" -ge 2 ] || die 2 "옵션에 값이 필요합니다: $1"
}

case "$target_type" in
  doc)
    while [ $# -gt 0 ]; do
      case "$1" in
        -h|--help) usage; exit 0 ;;
        -*)        die 2 "doc 대상에서는 사용할 수 없는 옵션입니다: $1" ;;
        *)
          [ -z "$doc_arg" ] || die 2 "설계 문서 경로는 하나만 입력할 수 있습니다: $1"
          doc_arg="$1"
          shift
          ;;
      esac
    done
    [ -n "$doc_arg" ] || die 2 "리뷰할 설계 문서 경로를 입력해야 합니다."
    ;;
  code)
    while [ $# -gt 0 ]; do
      case "$1" in
        --base)     need_value "$1" $#; base="$2"; shift 2 ;;
        --doc)      need_value "$1" $#; doc_arg="$2"; shift 2 ;;
        --remote)   need_value "$1" $#; remote="$2"; shift 2 ;;
        --no-fetch) no_fetch=true; shift ;;
        -h|--help)  usage; exit 0 ;;
        *)          die 2 "알 수 없는 인자입니다: $1" ;;
      esac
    done
    ;;
  *)
    usage >&2
    die 2 "리뷰 대상 유형은 doc 또는 code여야 합니다: '$target_type'"
    ;;
esac

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
check_doc_script="$script_dir/../../docs-create/scripts/check-doc.sh"

# ---------------------------------------------------------------------------
# 공통 함수
# ---------------------------------------------------------------------------

work_dir=""
findings_path=""

prepare_work_dir() {
  work_dir="$(mktemp -d "${TMPDIR:-/tmp}/deliverable-review.XXXXXX")" || die 1 "작업 디렉터리를 만들지 못했습니다."
  findings_path="$work_dir/findings.txt"
  : > "$findings_path"
}

# 자동 검사 항목을 "심각도 후보|종류|위치|내용" 형식으로 기록한다.
add_finding() {
  printf '%s|%s|%s|%s\n' "$1" "$2" "$3" "$(printf '%s' "$4" | tr '|' '/')" >> "$findings_path"
}

finding_count() {
  awk 'END { print NR }' "$findings_path"
}

print_findings() {
  local count
  count="$(finding_count)"
  if [ "$count" -eq 0 ]; then
    log "자동 검사에서 찾은 항목이 없습니다."
    return
  fi
  log "자동 검사 항목 (${count}개, 지적 후보):"
  head -n 30 "$findings_path" | awk -F'|' '{ printf "    [%s] %s - %s: %s\n", $1, $2, $3, $4 }' >&2
  if [ "$count" -gt 30 ]; then
    printf '    ... 외 %d개 (%s)\n' "$((count - 30))" "$findings_path" >&2
  fi
}

metadata_value() {
  local value
  value="$(LC_ALL=C sed -n "s/^| *$2 *| *\\([^|]*[^ |]\\) *|.*\$/\\1/p" "$1")"
  printf '%s' "${value%%$'\n'*}"
}

# 문서($1)에서 제목($2)부터 같은 수준 이상의 다음 제목 전까지의 본문을 출력한다.
section_body() {
  DOC_SECTION="$2" LC_ALL=C awk '
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
    }' "$1"
}

requirement_ids_of() {
  section_body "$1" '## 2. 요구사항' | { grep -oE '(NFR|FR)-[0-9]+' || true; } | LC_ALL=C sort -u
}

line_count() {
  if [ -z "$1" ]; then
    printf '0'
  else
    printf '%s\n' "$1" | wc -l | tr -d ' '
  fi
}

absolute_path() {
  printf '%s/%s' "$(cd "$(dirname "$1")" && pwd -P)" "$(basename "$1")"
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

is_test_file() {
  case "$1" in
    test/*|tests/*|spec/*|__tests__/*|*/test/*|*/tests/*|*/spec/*|*/__tests__/*) return 0 ;;
    *Test.java|*Tests.java|*Test.kt|*Tests.kt|*_test.go|*_test.py|test_*.py|*/test_*.py) return 0 ;;
    *.test.js|*.test.jsx|*.test.ts|*.test.tsx|*.spec.js|*.spec.jsx|*.spec.ts|*.spec.tsx) return 0 ;;
  esac
  return 1
}

is_source_file() {
  case "$1" in
    *.java|*.kt|*.go|*.py|*.js|*.jsx|*.ts|*.tsx|*.rs|*.rb|*.php|*.cs|*.swift|*.scala|*.c|*.cc|*.cpp|*.h) return 0 ;;
  esac
  return 1
}

# ---------------------------------------------------------------------------
# 설계 문서 리뷰 근거
# ---------------------------------------------------------------------------

review_doc() {
  [ -f "$doc_arg" ] || die 3 "설계 문서를 찾을 수 없습니다: $doc_arg"
  [ -f "$check_doc_script" ] \
    || die 1 "docs-create 스킬의 check-doc.sh를 찾을 수 없습니다. docs-create 스킬이 같은 skills 디렉터리에 있어야 합니다: $check_doc_script"

  local doc_path doc_name check_status check_output line doc_check doc_issues ids id
  local requirements untraced_tasks untraced_tests tasks_body tests_body unresolved_items unresolved doc_status

  doc_path="$(absolute_path "$doc_arg")"
  doc_name="$(basename "$doc_path")"
  prepare_work_dir

  check_status=0
  check_output="$(bash "$check_doc_script" "$doc_path" 2>&1 >/dev/null)" || check_status=$?
  doc_check=valid
  doc_issues=0
  case "$check_status" in
    0) ;;
    3)
      doc_check=invalid
      while IFS= read -r line; do
        case "$line" in
          "    - "*)
            doc_issues=$((doc_issues + 1))
            add_finding 중간 "문서 규칙" "$doc_name" "${line#    - }"
            ;;
        esac
      done <<< "$check_output"
      ;;
    *)
      printf '%s\n' "$check_output" >&2
      die 1 "설계 문서를 검사하지 못했습니다."
      ;;
  esac

  ids="$(requirement_ids_of "$doc_path")"
  requirements="$(line_count "$ids")"
  untraced_tasks=""
  untraced_tests=""
  if [ -n "$ids" ]; then
    tasks_body="$(section_body "$doc_path" '### 4.1 작업 목록')"
    tests_body="$(section_body "$doc_path" '## 5. 테스트 계획')"
    while IFS= read -r id; do
      # FR-1이 FR-10이나 NFR-1에 포함되어 찾아지지 않도록 앞뒤 문자를 확인한다.
      if ! grep -Eq "(^|[^A-Za-z0-9])$id([^0-9]|\$)" <<< "$tasks_body"; then
        untraced_tasks="${untraced_tasks:+$untraced_tasks,}$id"
        add_finding 중간 "요구사항 추적" "4.1 작업 목록" "작업 목록에 없는 요구사항 ID: $id"
      fi
      if ! grep -Eq "(^|[^A-Za-z0-9])$id([^0-9]|\$)" <<< "$tests_body"; then
        untraced_tests="${untraced_tests:+$untraced_tests,}$id"
        add_finding 중간 "요구사항 추적" "5. 테스트 계획" "테스트 계획에 없는 요구사항 ID: $id"
      fi
    done <<< "$ids"
  else
    warn "설계 문서의 2. 요구사항에서 요구사항 ID(FR-1, NFR-1 등)를 찾지 못했습니다."
  fi

  unresolved_items="$(section_body "$doc_path" '### 6.3 미결정 사항' \
    | { grep -E '^[[:space:]]*([-*]|[0-9]+\.) ' || true; } \
    | { grep -vE '^[[:space:]]*([-*]|[0-9]+\.) +(없음|해당 없음)\.?[[:space:]]*$' || true; })"
  unresolved="$(line_count "$unresolved_items")"
  if [ "$unresolved" -gt 0 ]; then
    log "6.3 미결정 사항 (${unresolved}개):"
    printf '%s\n' "$unresolved_items" | LC_ALL=C sed 's/^[[:space:]]*/    /' >&2
  fi

  doc_status="$(metadata_value "$doc_path" 상태)"
  print_findings

  printf 'RESULT=collected\n'
  printf 'TARGET_TYPE=doc\n'
  printf 'DOC_PATH=%s\n' "$doc_path"
  printf 'DOC_CHECK=%s\n' "$doc_check"
  printf 'DOC_ISSUES=%s\n' "$doc_issues"
  printf 'DOC_STATUS=%s\n' "${doc_status:--}"
  printf 'REQUIREMENTS=%s\n' "$requirements"
  printf 'UNTRACED_TASKS=%s\n' "$untraced_tasks"
  printf 'UNTRACED_TESTS=%s\n' "$untraced_tests"
  printf 'UNRESOLVED=%s\n' "$unresolved"
  printf 'AUTO_FINDINGS=%s\n' "$(finding_count)"
  printf 'FINDINGS_PATH=%s\n' "$findings_path"
}

# ---------------------------------------------------------------------------
# 코드 변경 리뷰 근거
# ---------------------------------------------------------------------------

review_code() {
  [ "$(git rev-parse --is-inside-work-tree 2>/dev/null || true)" = true ] \
    || die 1 "리뷰할 Git 저장소의 작업 트리 안에서 실행해야 합니다."

  local state
  for state in rebase-merge rebase-apply MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD; do
    if [ -e "$(git rev-parse --git-path "$state")" ]; then
      die 1 "진행 중인 Git 작업이 있습니다. 해당 작업을 완료하거나 중단한 뒤 다시 실행하세요: $state"
    fi
  done

  local branch repo_root has_remote remote_branches ls_output candidates candidate found
  local base_ref base_label fetch_output merge_base commits diff_path untracked file
  local name_status changed_list changed_files uncommitted_files added_lines deleted_lines
  local test_files source_files path status whitespace_output whitespace_count
  local doc_path requirements issue_pattern issue_number matches match_count

  branch="$(git symbolic-ref --quiet --short HEAD || true)"
  [ -n "$branch" ] || branch="HEAD"
  repo_root="$(git rev-parse --show-toplevel)"

  # 기준 브랜치 결정
  has_remote=false
  if grep -Fxq -- "$remote" <<< "$(git remote)"; then
    has_remote=true
  elif [ "$no_fetch" = false ]; then
    warn "원격 저장소를 찾을 수 없어 로컬 브랜치만 확인합니다: '$remote'"
  fi

  remote_branches=""
  if [ "$has_remote" = true ]; then
    if [ "$no_fetch" = true ]; then
      remote_branches="$(git for-each-ref --format='%(refname:lstrip=3)' "refs/remotes/$remote/")"
    else
      if ! ls_output="$(git ls-remote --heads "$remote" 2>&1)"; then
        die 5 "원격 저장소 조회에 실패했습니다. 네트워크와 인증 상태를 확인하세요: $remote
$ls_output"
      fi
      remote_branches="$(sed -n 's#^[0-9a-f]*[[:space:]]*refs/heads/##p' <<< "$ls_output")"
    fi
  fi

  if [ -n "$base" ]; then
    base="${base#refs/heads/}"
    base="${base#"$remote"/}"
    candidates="$base"
  else
    candidates="$BASE_CANDIDATES"
  fi

  found=""
  for candidate in $candidates; do
    if { [ -n "$remote_branches" ] && grep -Fxq -- "$candidate" <<< "$remote_branches"; } \
      || git show-ref --verify --quiet "refs/heads/$candidate"; then
      found="${found:+$found }$candidate"
    fi
  done
  [ -n "$found" ] || die 4 "기준 브랜치를 찾을 수 없습니다: ${base:-$BASE_CANDIDATES}. 사용자에게 기준 브랜치를 확인하고 --base로 지정하세요."
  case "$found" in
    *" "*) die 4 "기준 브랜치 후보가 여러 개입니다($found). 사용자에게 기준 브랜치를 확인하고 --base로 지정하세요." ;;
  esac
  base="$found"
  [ "$base" != "$branch" ] || die 2 "현재 브랜치와 기준 브랜치가 같습니다: '$base'. 리뷰할 작업 브랜치로 전환하거나 --base를 지정하세요."

  if [ -n "$remote_branches" ] && grep -Fxq -- "$base" <<< "$remote_branches"; then
    base_ref="refs/remotes/$remote/$base"
    base_label="$remote/$base"
    if [ "$no_fetch" = false ]; then
      if ! fetch_output="$(git fetch --quiet "$remote" "+refs/heads/$base:$base_ref" 2>&1)"; then
        die 5 "기준 브랜치를 fetch하지 못했습니다: $base_label
$fetch_output"
      fi
    fi
  else
    base_ref="refs/heads/$base"
    base_label="$base"
  fi

  merge_base="$(git merge-base HEAD "$base_ref" 2>/dev/null || true)"
  [ -n "$merge_base" ] || die 3 "현재 브랜치와 기준 브랜치의 공통 조상 커밋을 찾을 수 없습니다: $base_label"

  # 변경 목록과 diff (커밋하지 않은 변경과 새 파일 포함)
  prepare_work_dir
  diff_path="$work_dir/changes.diff"
  git -c core.quotePath=false diff -M --no-color "$merge_base" > "$diff_path"
  untracked="$(git -c core.quotePath=false ls-files --others --exclude-standard)"
  if [ -n "$untracked" ]; then
    while IFS= read -r file; do
      git -c core.quotePath=false diff --no-color --no-index -- /dev/null "$file" >> "$diff_path" || true
    done <<< "$untracked"
  fi

  name_status="$(git -c core.quotePath=false diff -M --name-status "$merge_base")"
  changed_list="$({ awk -F'\t' 'NF { print $NF }' <<< "$name_status"; printf '%s\n' "$untracked"; } | awk 'NF' | LC_ALL=C sort -u)"
  changed_files="$(line_count "$changed_list")"
  [ "$changed_files" -gt 0 ] || die 3 "기준 브랜치($base_label)와 비교해 리뷰할 변경 사항이 없습니다."

  commits="$(git rev-list --count "$merge_base..HEAD")"
  uncommitted_files="$(git status --porcelain --untracked-files=all | awk 'END { print NR }')"
  added_lines="$(awk '/^\+/ && !/^\+\+\+ / { n++ } END { print n + 0 }' "$diff_path")"
  deleted_lines="$(awk '/^-/ && !/^--- / { n++ } END { print n + 0 }' "$diff_path")"

  # 파일 단위 검사 (삭제한 파일은 제외)
  test_files=0
  source_files=0
  while IFS="$(printf '\t')" read -r status path; do
    [ -n "$path" ] || continue
    case "$status" in
      D*) continue ;;
      R*) path="${path##*$'\t'}" ;;
    esac
    if is_test_file "$path"; then
      test_files=$((test_files + 1))
    elif is_source_file "$path"; then
      source_files=$((source_files + 1))
    fi
    if is_sensitive_file "$path"; then
      add_finding 높음 "민감한 파일" "$path" "민감한 파일로 의심되는 파일이 변경 사항에 있습니다."
    fi
  done <<< "$(awk -F'\t' 'NF { print $1 "\t" $NF }' <<< "$name_status"; if [ -n "$untracked" ]; then awk '{ print "A\t" $0 }' <<< "$untracked"; fi)"

  if [ "$source_files" -gt 0 ] && [ "$test_files" -eq 0 ]; then
    add_finding 중간 "테스트" "-" "소스 파일 ${source_files}개가 변경되었지만 테스트 파일 변경이 없습니다."
  fi

  # 추가한 줄 검사: 충돌 표시, 민감 정보, 디버그 출력, TODO
  local value_char secret_pattern
  value_char="[^\"'[:space:]]"
  secret_pattern="(password|passwd|secret|api[_-]?key|access[_-]?key|access[_-]?token|private[_-]?key|client[_-]?secret)[\"']?[[:space:]]*[:=][[:space:]]*[\"'][^\"'[:space:]\$<]$value_char$value_char$value_char$value_char$value_char$value_char$value_char$value_char*[\"']"
  SECRET_PATTERN="$secret_pattern" LC_ALL=C awk '
    function trim(s) {
      sub(/^[ \t]+/, "", s)
      sub(/[ \t\r]+$/, "", s)
      return s
    }
    function clean(s) {
      s = trim(s)
      gsub(/\|/, "/", s)
      return substr(s, 1, 120)
    }
    /^\+\+\+ / {
      file = substr($0, 5)
      sub(/^b\//, "", file)
      next
    }
    /^@@ / {
      if (match($0, /\+[0-9]+/)) line = substr($0, RSTART + 1, RLENGTH - 1) - 1
      next
    }
    /^\+/ {
      line++
      text = substr($0, 2)
      location = file ":" line
      if (text ~ /^(<<<<<<<|=======|>>>>>>>)( |$)/) print "높음|충돌 표시|" location "|merge 충돌 표시가 남아 있습니다."
      if (tolower(text) ~ ENVIRON["SECRET_PATTERN"]) print "높음|민감 정보|" location "|비밀번호나 키로 의심되는 값이 있습니다. (값은 기록하지 않음)"
      if (text ~ /console\.log\(|System\.out\.print|printStackTrace\(\)|debugger;|fmt\.Print|var_dump\(/) print "낮음|디버그 출력|" location "|" clean(text)
      if (text ~ /(TODO|FIXME)/) print "낮음|TODO|" location "|" clean(text)
      next
    }
    /^ / { line++ }
  ' "$diff_path" >> "$findings_path"

  whitespace_output="$(git -c core.quotePath=false diff --check "$merge_base" 2>/dev/null || true)"
  whitespace_count="$(printf '%s\n' "$whitespace_output" | awk '/^[^+ ].*:[0-9]+: / { n++ } END { print n + 0 }')"
  if [ "$whitespace_count" -gt 0 ]; then
    add_finding 낮음 "공백 오류" "$(printf '%s\n' "$whitespace_output" | awk -F': ' '/^[^+ ].*:[0-9]+: / { print $1; exit }')" "공백 오류 ${whitespace_count}건이 있습니다. (git diff --check로 확인)"
  fi

  # 함께 리뷰할 설계 문서
  doc_path=""
  requirements=""
  if [ -n "$doc_arg" ]; then
    [ -f "$doc_arg" ] || die 3 "설계 문서를 찾을 수 없습니다: $doc_arg"
    doc_path="$(absolute_path "$doc_arg")"
  else
    issue_pattern='^[a-z]+/([0-9]+)-'
    if [[ "$branch" =~ $issue_pattern ]] && [ -d "$repo_root/docs" ]; then
      issue_number="${BASH_REMATCH[1]}"
      matches="$(find "$repo_root/docs" -mindepth 2 -maxdepth 2 -type f -name '*.md' \
        ! -name '*-review.md' ! -name '*-review-[0-9]*.md' \
        -exec grep -l -E "^\| *관련 이슈 *\| *#$issue_number *\|" {} + 2>/dev/null | LC_ALL=C sort || true)"
      match_count="$(line_count "$matches")"
      if [ "$match_count" -eq 1 ]; then
        doc_path="$matches"
        log "브랜치의 이슈 번호(#$issue_number)와 관련 이슈가 같은 설계 문서를 찾았습니다: ${doc_path#"$repo_root"/}"
      elif [ "$match_count" -gt 1 ]; then
        warn "관련 이슈가 #$issue_number인 설계 문서가 여러 개입니다. 함께 리뷰할 문서를 사용자에게 확인하고 --doc으로 지정하세요."
        printf '%s\n' "$matches" | while IFS= read -r file; do printf '    %s\n' "${file#"$repo_root"/}"; done >&2
      fi
    fi
  fi
  if [ -n "$doc_path" ]; then
    requirements="$(line_count "$(requirement_ids_of "$doc_path")")"
  fi

  log "변경 파일 (${changed_files}개):"
  {
    awk -F'\t' 'NF { printf "    %-4s %s\n", substr($1, 1, 1), $NF }' <<< "$name_status"
    if [ -n "$untracked" ]; then awk '{ printf "    %-4s %s\n", "?", $0 }' <<< "$untracked"; fi
  } | head -n 50 >&2
  if [ "$commits" -gt 0 ]; then
    log "커밋 (${commits}개):"
    git log --oneline --no-decorate --max-count=20 "$merge_base..HEAD" | LC_ALL=C sed 's/^/    /' >&2
  fi
  print_findings

  printf 'RESULT=collected\n'
  printf 'TARGET_TYPE=code\n'
  printf 'BRANCH=%s\n' "$branch"
  printf 'BASE=%s\n' "$base_label"
  printf 'MERGE_BASE=%s\n' "$(git rev-parse --short "$merge_base")"
  printf 'COMMITS=%s\n' "$commits"
  printf 'CHANGED_FILES=%s\n' "$changed_files"
  printf 'UNCOMMITTED_FILES=%s\n' "$uncommitted_files"
  printf 'ADDED_LINES=%s\n' "$added_lines"
  printf 'DELETED_LINES=%s\n' "$deleted_lines"
  printf 'TEST_FILES_CHANGED=%s\n' "$test_files"
  printf 'DOC_PATH=%s\n' "$doc_path"
  printf 'REQUIREMENTS=%s\n' "$requirements"
  printf 'AUTO_FINDINGS=%s\n' "$(finding_count)"
  printf 'DIFF_PATH=%s\n' "$diff_path"
  printf 'FINDINGS_PATH=%s\n' "$findings_path"
}

case "$target_type" in
  doc)  review_doc ;;
  code) review_code ;;
esac
