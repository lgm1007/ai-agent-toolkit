---
name: develop-by-docs
description: docs-create 스킬로 작성한 구현 설계 문서의 경로를 받아, 문서의 요구사항, 설계, 작업 목록, 테스트 계획에 따라 실제 코드를 구현하고 빌드와 테스트까지 수행한다. 구현 전에 현재 브랜치가 main, develop, dev 같은 보호 브랜치가 아닌 별도 작업 브랜치인지 확인한다. 설계 문서를 바탕으로 구현, 설계서대로 개발, 문서 기반 구현을 요청받았을 때 사용한다.
---

# 설계 문서 기반 구현

docs-create 스킬로 작성한 구현 설계 문서를 기준으로 코드를 구현하고, 빌드와 테스트까지 수행한다.
구현 전 확인은 `scripts/preflight.sh`로, 빌드와 테스트는 `scripts/build.sh`로 수행해서, 누가 실행하더라도 같은 조건에서 구현을 시작하고 같은 방식으로 빌드하도록 한다.

## 입력

| 입력 | 필수 여부 | 설명 |
|---|---|---|
| 설계 문서 경로 | 필수 | docs-create 스킬로 작성한 문서 경로 (예: `docs/260915/kakao-social-login.md`) |

설계 문서 경로를 받지 못했다면 구현을 시작하기 전에 사용자에게 요청한다. `docs/` 아래의 문서를 임의로 골라 구현하지 않는다.

## 구현 규칙

### 작업 브랜치

1. 구현은 main, master, develop, dev, development 같은 보호 브랜치가 아닌 별도 작업 브랜치에서만 수행한다.
2. 보호 브랜치에 있으면 코드를 수정하지 않고 멈춘다. git-branch 스킬이나 git-worktree 스킬로 작업 브랜치를 만들지 사용자에게 확인한다.
3. 브랜치 이름에 들어 있는 이슈 번호가 설계 문서의 관련 이슈와 다르다는 경고가 나오면, 올바른 브랜치인지 사용자에게 확인한다.

### 설계 문서 준수

1. 설계 문서가 구현 범위의 기준이다. 문서에 없는 기능이나 리팩토링을 임의로 추가하지 않는다.
2. 구현은 4.1 작업 목록의 순서를 따르고, 4.2 변경 대상에 적힌 범위 안에서 코드를 수정한다.
3. 실제 코드가 문서와 달라서 설계대로 구현할 수 없으면 멈추고 사용자에게 알린다. 설계를 바꾸기로 합의하면 docs-create 스킬 규칙에 따라 문서를 먼저 수정하고 변경 이력을 남긴 뒤 구현한다.
4. 6.3 미결정 사항 중 구현에 영향을 주는 항목은 해당 부분을 구현하기 전에 사용자에게 확인한다.
5. 설계 문서가 초안 상태라는 경고가 나오면, 초안 문서로 구현을 시작한다는 사실을 사용자에게 알린다.

### 코드 작성

1. 기존 코드의 구조, 이름 규칙, 코드 스타일, 사용 중인 라이브러리를 따른다.
2. 5. 테스트 계획에 적힌 시나리오를 테스트 코드로 작성한다.
3. 비밀번호, API 키, 토큰 같은 민감 정보를 코드에 직접 쓰지 않고, 프로젝트의 기존 설정 방식을 따른다.
4. 데이터베이스 마이그레이션 실행, 외부 API 호출, 배포처럼 로컬 밖에 영향을 주는 작업은 사용자 승인 없이 실행하지 않는다.

### 빌드와 테스트

1. 구현을 마치면 반드시 `build.sh`로 빌드와 테스트를 실행한다.
2. 실패하면 로그를 보고 원인을 수정한 뒤 다시 실행한다. 같은 원인으로 3번 연속 실패하면 멈추고 사용자에게 보고한다.
3. 빌드를 통과시키려고 테스트를 삭제하거나 비활성화하거나, 테스트를 건너뛰는 옵션(`--no-test`, `-x test`, `-DskipTests` 등)을 사용하지 않는다. 테스트를 건너뛰어야 한다면 사용자 승인을 받는다.
4. 빌드 도구를 자동으로 찾지 못하면 사용자에게 빌드 명령을 확인하고 `--command`로 지정한다.
5. 의존성이 설치되어 있지 않아서 실패하면, 프로젝트의 설치 명령을 사용자에게 확인한 뒤 실행한다.

## 실행 절차

1. 사용자에게 설계 문서 경로를 받는다.
2. 구현할 Git 저장소(worktree에서 작업한다면 해당 worktree) 안에서 `preflight.sh`를 실행해 작업 브랜치, 작업 트리, 설계 문서를 확인한다.
3. 종료 코드가 0이 아니면 아래의 "종료 코드별 대응" 표에 따라 처리한다.
4. 설계 문서 전체를 읽고, 4.2 변경 대상과 관련 코드를 조사한다.
5. 초안 상태 경고나 구현에 영향을 주는 미결정 사항이 있으면 사용자에게 확인한다.
6. 4.1 작업 목록의 순서대로 구현하고, 5. 테스트 계획에 따라 테스트 코드를 작성한다.
7. `build.sh`로 빌드와 테스트를 실행하고, 실패하면 수정해서 통과시킨다.
8. 아래 항목으로 완료 보고를 한다.
   - 요구사항 ID(FR-1 등)별 구현 내용, 변경한 파일, 작성한 테스트
   - 빌드 결과 (빌드 도구, 실행 명령, 성공 여부, 로그 경로)
   - 설계 문서와 다르게 구현한 부분과 그 이유
   - 남아 있는 미결정 사항과 후속 작업

- 커밋과 push는 사용자가 요청한 경우에만 git-commit, git-push 스킬로 수행한다.
- 구현 과정에서 설계 문서를 고쳐야 할 내용이 생기면 사용자에게 알리고, 수정은 docs-create 스킬 규칙을 따른다.

## 스크립트 사용법

스크립트는 이 SKILL.md가 있는 디렉터리를 기준으로 `scripts/`에 있다. Claude Code에서는 `<스킬 디렉터리>` 자리에 `${CLAUDE_SKILL_DIR}`를 사용한다.
`preflight.sh`는 docs-create 스킬의 `scripts/check-doc.sh`로 설계 문서를 검증하므로, docs-create 스킬이 같은 skills 디렉터리에 있어야 한다.

### preflight.sh

```bash
bash <스킬 디렉터리>/scripts/preflight.sh <설계 문서 경로> [옵션]

# 예시
bash <스킬 디렉터리>/scripts/preflight.sh docs/260915/kakao-social-login.md
```

| 옵션 | 설명 |
|---|---|
| `--allow-dirty` | 커밋되지 않은 변경 사항이 있어도 진행한다. 사용자 승인이 필요하다. |
| `--allow-invalid-doc` | 설계 문서가 docs-create 규칙에 맞지 않아도 진행한다. 사용자 승인이 필요하다. |

- 설계 문서 파일 자체의 변경 사항(새로 만든 문서 포함)은 커밋되지 않은 변경 사항으로 보지 않는다.
- 요구사항 ID, 4.1 작업 목록의 체크리스트 항목, 6.3 미결정 사항의 목록 항목 개수를 세고, 미결정 사항은 표준 에러에 함께 출력한다.

```
RESULT=ready
BRANCH=feat/128-add-kakao-social-login
DOC_PATH=/path/to/project/docs/260915/kakao-social-login.md
DOC_STATUS=확정
REQUIREMENTS=5
TASKS=7
UNRESOLVED=1
BUILD_TOOL=gradle
```

| 코드 | 의미 | 대응 |
|---|---|---|
| 0 | 구현 준비 완료 | 경고를 확인하고 구현을 시작한다. |
| 1 | 저장소 상태 오류 | 오류 메시지를 보고한다. Git 저장소가 아니거나, detached HEAD이거나, rebase 등이 진행 중이거나, docs-create 스킬이 없는 경우다. |
| 2 | 인자 오류 | 설계 문서 경로를 하나만 전달해 다시 실행한다. |
| 3 | 보호 브랜치에서 실행 | 코드를 수정하지 않는다. git-branch 스킬이나 git-worktree 스킬로 작업 브랜치를 만들지 사용자에게 확인한다. |
| 4 | 커밋되지 않은 변경 사항 존재 | 변경 파일 목록을 보여 주고, 구현 변경과 섞어도 되는지 사용자에게 확인한다. |
| 5 | 설계 문서 없음 또는 규칙 위반 | 경로를 확인한다. 규칙 위반이면 문서를 고칠지, 그대로 구현할지(`--allow-invalid-doc`) 사용자에게 확인한다. |

### build.sh

```bash
bash <스킬 디렉터리>/scripts/build.sh [옵션]

# 예시
bash <스킬 디렉터리>/scripts/build.sh
bash <스킬 디렉터리>/scripts/build.sh --command "./gradlew :api:build --console=plain"
```

| 옵션 | 설명 |
|---|---|
| `--command <명령>` | 자동 감지 대신 지정한 명령으로 빌드한다. 하위 모듈만 빌드하거나 감지되지 않는 프로젝트에 사용한다. |
| `--no-test` | 테스트를 제외하고 빌드한다. 사용자 승인이 필요하다. |
| `--detect-only` | 빌드 도구와 실행할 명령만 확인하고 빌드하지 않는다. |

빌드 도구는 프로젝트 루트(Git 저장소 최상위 디렉터리)의 파일을 아래 표의 순서대로 확인해서 먼저 찾은 것을 사용한다.

| 감지 기준 | 빌드 도구 | 실행 명령 | `--no-test` 사용 시 |
|---|---|---|---|
| `gradlew` | gradle | `./gradlew build --console=plain` | `./gradlew assemble --console=plain` |
| `build.gradle`, `build.gradle.kts` | gradle | `gradle build --console=plain` | `gradle assemble --console=plain` |
| `mvnw` | maven | `./mvnw -B verify` | `./mvnw -B package -DskipTests` |
| `pom.xml` | maven | `mvn -B verify` | `mvn -B package -DskipTests` |
| `package.json` | pnpm, yarn, bun, npm (lock 파일 기준) | `<도구> run build`, `<도구> run test` | `<도구> run build` |
| `go.mod` | go | `go build ./...`, `go test ./...` | `go build ./...` |
| `Cargo.toml` | cargo | `cargo build`, `cargo test` | `cargo build` |

- `package.json`은 scripts에 있는 build, test 스크립트만 실행한다. test 스크립트는 `CI=true` 환경에서 실행해 watch 모드로 멈추지 않게 한다.
- 빌드 로그는 임시 디렉터리에 저장하고, 실패하면 로그의 마지막 40줄을 표준 에러에 출력한다.

```
RESULT=success
BUILD_TOOL=gradle
BUILD_COMMAND=./gradlew build --console=plain
TEST_INCLUDED=true
FAILED_COMMAND=
LOG_PATH=/tmp/develop-by-docs.a1B2c3/build.log
```

- `RESULT`: 성공하면 `success`, 실패하면 `failure`, `--detect-only`로 실행했으면 `detected`
- `TEST_INCLUDED`: 테스트를 함께 실행했는지 여부 (`--command`를 사용하면 `unknown`)

| 코드 | 의미 | 대응 |
|---|---|---|
| 0 | 빌드 성공 | 완료 보고에 빌드 결과를 포함한다. |
| 1 | 환경 오류 | 오류 메시지를 보고한다. |
| 2 | 인자 오류 | 옵션을 확인해 다시 실행한다. |
| 3 | 빌드 도구를 찾지 못함 | 사용자에게 빌드 명령을 확인하고 `--command`로 지정한다. |
| 4 | 빌드 또는 테스트 실패 | 로그를 확인해 원인을 수정하고 다시 실행한다. 같은 원인으로 3번 연속 실패하면 사용자에게 보고한다. |

## 주의 사항

- 보호 브랜치에서 코드를 수정하지 않는다.
- 설계 문서 범위를 벗어난 변경은 사용자 동의 없이 하지 않는다.
- 테스트를 삭제, 비활성화하거나 빌드 검사를 우회해서 빌드를 통과시키지 않는다.
- 빌드 명령은 프로젝트의 빌드 스크립트를 실행하므로, 처음 받은 외부 저장소라면 빌드 전에 사용자에게 확인한다.
