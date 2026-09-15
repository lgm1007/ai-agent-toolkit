#!/usr/bin/env bash
#
# develop-by-docs 스킬 규칙에 따라 프로젝트의 빌드 도구를 감지해 빌드와 테스트를 실행한다.
#
# 빌드 도구 감지, 실행 명령 결정, 로그 저장을 이 스크립트가 일괄 처리하므로
# 어떤 에이전트가 실행하더라도 같은 명령으로 빌드하고 같은 형식으로 결과를 보고한다.
#
# 사용법:
#   build.sh [--command <빌드 명령>] [--no-test] [--detect-only]
#
# 결과 (표준 출력, key=value 형식):
#   RESULT=success | failure | detected
#   BUILD_TOOL=<gradle, maven, pnpm, yarn, bun, npm, go, cargo, custom 중 하나>
#   BUILD_COMMAND=<실행할 명령, 여러 개면 ' && '로 연결>
#   TEST_INCLUDED=true | false | unknown
#   FAILED_COMMAND=<실패한 명령, 성공하면 빈 값>
#   LOG_PATH=<빌드 로그 경로, --detect-only면 빈 값>
#
# 종료 코드:
#   0  빌드 성공 (--detect-only는 감지 성공)
#   1  환경 오류
#   2  인자 오류
#   3  빌드 도구를 찾지 못함
#   4  빌드 또는 테스트 실패
#
# 요구 사항: bash 3.2 이상

set -euo pipefail

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
사용법: build.sh [옵션]

프로젝트 루트(Git 저장소 최상위 디렉터리)의 빌드 도구를 감지해 빌드와 테스트를 실행한다.

옵션:
  --command <명령>   자동 감지 대신 지정한 명령으로 빌드한다
  --no-test          테스트를 제외하고 빌드한다 (사용자 승인 필요)
  --detect-only      빌드 도구와 실행할 명령만 확인하고 빌드하지 않는다
  -h, --help         도움말을 출력한다

감지 순서: gradlew, build.gradle(.kts), mvnw, pom.xml, package.json, go.mod, Cargo.toml
EOF
}

# ---------------------------------------------------------------------------
# 인자 해석
# ---------------------------------------------------------------------------

custom_command=""
command_given=false
run_tests=true
detect_only=false

need_value() {
  [ "$2" -ge 2 ] || die 2 "옵션에 값이 필요합니다: $1"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --command)     need_value "$1" $#; custom_command="$2"; command_given=true; shift 2 ;;
    --no-test)     run_tests=false; shift ;;
    --detect-only) detect_only=true; shift ;;
    -h|--help)     usage; exit 0 ;;
    *)             die 2 "알 수 없는 인자입니다: $1" ;;
  esac
done

if [ "$command_given" = true ] && [ -z "$(printf '%s' "$custom_command" | tr -d '[:space:]')" ]; then
  die 2 "--command 옵션에 실행할 명령을 입력해야 합니다."
fi

if root="$(git rev-parse --show-toplevel 2>/dev/null)"; then
  :
else
  root="$(pwd)"
fi
cd "$root" || die 1 "프로젝트 루트로 이동하지 못했습니다: $root"

# ---------------------------------------------------------------------------
# 빌드 도구와 실행 명령 결정
# ---------------------------------------------------------------------------

tool=""
steps=""
tests_included=false

add_step() {
  if [ -z "$steps" ]; then
    steps="$1"
  else
    steps="$steps"$'\n'"$1"
  fi
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die 3 "$2"
}

has_package_script() {
  LC_ALL=C grep -Eq "\"$1\"[[:space:]]*:" package.json
}

set_gradle_steps() {
  if [ "$run_tests" = true ]; then
    add_step "$1 build --console=plain"
    tests_included=true
  else
    add_step "$1 assemble --console=plain"
  fi
}

set_maven_steps() {
  if [ "$run_tests" = true ]; then
    add_step "$1 -B verify"
    tests_included=true
  else
    add_step "$1 -B package -DskipTests"
  fi
}

# 실행 권한이 없는 wrapper 파일(Windows에서 커밋한 경우 등)은 sh로 실행한다.
wrapper_command() {
  if [ -x "$1" ]; then
    printf './%s' "$1"
  else
    printf 'sh ./%s' "$1"
  fi
}

if [ "$command_given" = true ]; then
  tool=custom
  tests_included=unknown
  add_step "$custom_command"
  [ "$run_tests" = true ] || warn "--command를 지정하면 --no-test 옵션은 적용되지 않습니다."
elif [ -f gradlew ]; then
  tool=gradle
  set_gradle_steps "$(wrapper_command gradlew)"
elif [ -f build.gradle ] || [ -f build.gradle.kts ]; then
  require_command gradle "Gradle 프로젝트이지만 gradlew 파일과 gradle 명령을 찾을 수 없습니다."
  tool=gradle
  set_gradle_steps gradle
elif [ -f mvnw ]; then
  tool=maven
  set_maven_steps "$(wrapper_command mvnw)"
elif [ -f pom.xml ]; then
  require_command mvn "Maven 프로젝트이지만 mvnw 파일과 mvn 명령을 찾을 수 없습니다."
  tool=maven
  set_maven_steps mvn
elif [ -f package.json ]; then
  if [ -f pnpm-lock.yaml ]; then
    tool=pnpm
  elif [ -f yarn.lock ]; then
    tool=yarn
  elif [ -f bun.lockb ] || [ -f bun.lock ]; then
    tool=bun
  else
    tool=npm
  fi
  require_command "$tool" "package.json 프로젝트이지만 $tool 명령을 찾을 수 없습니다."
  if has_package_script build; then
    add_step "$tool run build"
  fi
  if [ "$run_tests" = true ]; then
    # npm init이 만드는 기본 test 스크립트("no test specified")는 테스트로 보지 않는다.
    if has_package_script test && ! LC_ALL=C grep -q 'no test specified' package.json; then
      add_step "$tool run test"
      tests_included=true
    else
      warn "package.json에 test 스크립트가 없어 테스트를 실행하지 않습니다."
    fi
  fi
  [ -n "$steps" ] || die 3 "package.json에 실행할 build나 test 스크립트가 없습니다. 사용자에게 빌드 명령을 확인하고 --command로 지정하세요."
elif [ -f go.mod ]; then
  require_command go "go.mod가 있지만 go 명령을 찾을 수 없습니다."
  tool=go
  add_step "go build ./..."
  if [ "$run_tests" = true ]; then
    add_step "go test ./..."
    tests_included=true
  fi
elif [ -f Cargo.toml ]; then
  require_command cargo "Cargo.toml이 있지만 cargo 명령을 찾을 수 없습니다."
  tool=cargo
  add_step "cargo build"
  if [ "$run_tests" = true ]; then
    add_step "cargo test"
    tests_included=true
  fi
else
  die 3 "빌드 도구를 찾지 못했습니다. 사용자에게 빌드 명령을 확인하고 --command로 지정하세요."
fi

if [ "$run_tests" = false ] && [ "$command_given" = false ]; then
  warn "--no-test 옵션에 따라 테스트를 제외하고 빌드합니다."
fi

build_command="$(printf '%s\n' "$steps" | awk 'NR > 1 { printf " && " } { printf "%s", $0 }')"
failed_command=""
log_path=""

print_result() {
  printf 'RESULT=%s\n' "$1"
  printf 'BUILD_TOOL=%s\n' "$tool"
  printf 'BUILD_COMMAND=%s\n' "$build_command"
  printf 'TEST_INCLUDED=%s\n' "$tests_included"
  printf 'FAILED_COMMAND=%s\n' "$failed_command"
  printf 'LOG_PATH=%s\n' "$log_path"
}

if [ "$detect_only" = true ]; then
  print_result detected
  exit 0
fi

# ---------------------------------------------------------------------------
# 빌드 실행
# ---------------------------------------------------------------------------

log_dir="$(mktemp -d "${TMPDIR:-/tmp}/develop-by-docs.XXXXXX")" || die 1 "빌드 로그 디렉터리를 만들지 못했습니다."
log_path="$log_dir/build.log"
: > "$log_path"

# 테스트 러너가 watch 모드로 멈추지 않도록 package.json의 test 스크립트는 CI=true로 실행한다.
run_step() {
  case "$1" in
    *" run test") CI="${CI:-true}" bash -c "$1" ;;
    *)            bash -c "$1" ;;
  esac
}

# 빌드 명령이 표준 입력을 읽어 남은 단계 목록을 소비하지 않도록 표준 입력은 /dev/null로 연결한다.
while IFS= read -r step; do
  log "실행합니다: $step"
  printf '$ %s\n' "$step" >> "$log_path"
  if ! run_step "$step" < /dev/null >> "$log_path" 2>&1; then
    failed_command="$step"
    break
  fi
done <<< "$steps"

if [ -n "$failed_command" ]; then
  log "빌드 로그의 마지막 40줄:"
  tail -n 40 "$log_path" | LC_ALL=C sed 's/^/    /' >&2
  print_result failure
  printf '[develop-by-docs] 오류: %s\n' "빌드 또는 테스트가 실패했습니다: $failed_command (로그: $log_path)" >&2
  exit 4
fi

log "빌드를 완료했습니다. (로그: $log_path)"
print_result success
