---
name: git-branch
description: 작업 내용을 분석해 prefix(feat, fix, refactor, chore, docs, test)와 영문 브랜치명을 결정하고, develop/dev 같은 개발 브랜치에서 새 Git 브랜치를 생성한다. 새 작업 브랜치 생성(브랜치 따기), 브랜치 분기, 브랜치명 작성을 요청받았을 때 사용한다.
---

# Git 브랜치 생성

작업 내용에 맞는 브랜치명을 규칙에 따라 결정하고, 개발 브랜치에서 새 브랜치를 생성한다.
브랜치명 조합, 검증, 생성은 반드시 `scripts/create-branch.sh`로 수행해서, 누가 실행하더라도 같은 규칙의 결과를 얻도록 한다.

## 생성 규칙

1. 신규 브랜치는 main 브랜치가 아닌 develop 나 dev 와 같은 개발 브랜치에서 파생한다.
2. 작업의 성격을 분석해 prefix를 결정한다.
3. 현재 체크아웃된 브랜치와 관계없이 개발 브랜치에서 파생한다. 다른 작업 브랜치에서 파생하는 것은 사용자가 기준 브랜치를 명시한 경우에만 허용한다.
4. 로컬 개발 브랜치는 오래된 상태일 수 있으므로, 원격 저장소의 최신 개발 브랜치(`origin/develop` 등)에서 파생한다.
5. 개발 브랜치 후보(develop, dev, development)가 없거나 여러 개면 임의로 고르지 않고 사용자에게 기준 브랜치를 확인한다.
6. main/master에서 파생하는 것은 사용자가 명시적으로 요청한 경우(운영 환경 긴급 수정 등)에만 허용한다.
7. 같은 이름의 브랜치가 로컬이나 원격에 이미 있으면 덮어쓰지 않는다.
8. 이 스킬은 브랜치 생성과 체크아웃까지만 수행한다. 원격 push와 upstream 설정은 `git-push` 스킬에서 수행한다.

## prefix 규칙

- feat/ : 구현, 추가, 개발 기능
- fix/ : 수정 사항, 에러 및 버그
- refactor/ : 리팩토링 및 개선, 정리 작업
- chore/ : 환경 설정, 빌드 관련 작업
- docs/ : 문서, 주석 작성
- test/ : 테스트 코드

### prefix 판단 기준

- 위 6개 외의 prefix(feature/, bugfix/, hotfix/, style/ 등)는 사용하지 않는다.
- 여러 성격이 섞인 작업은 주된 목적 하나를 기준으로 prefix를 결정한다.
- 아래 기준으로도 판단하기 어려우면 후보 prefix와 판단 근거를 제시하고 사용자에게 확인한다.

| 작업 상황 | prefix |
|---|---|
| 기능을 구현하면서 테스트 코드도 함께 작성 | `feat/` |
| 버그를 수정하면서 관련 코드를 일부 정리 | `fix/` |
| 기능 동작의 변경 없이 성능, 구조, 코드 포맷을 개선 | `refactor/` |
| 의존성 버전 업그레이드, CI/CD, 빌드 스크립트, 환경 설정 파일 변경 | `chore/` |
| README, API 문서, 코드 주석만 작성하거나 수정 | `docs/` |
| 기존 코드에 대한 테스트 코드만 추가하거나 수정 | `test/` |

## 브랜치명 규칙

- 작업에 대한 설명을 간단한 영문 작업명으로 번역해 작성한다.
- 띄어쓰기는 `-` 문자로 작성한다.
- 브랜치명 길이는 가능하면 50자 이내로 작성한다.

### 세부 규칙

- 형식은 `<prefix>/<작업명>`이다. 이슈 번호가 주어지면 `<prefix>/<이슈 번호>-<작업명>`으로 작성한다.
- 영문 소문자, 숫자, `-`만 사용한다. 대문자, 한글, 공백, `_`, `.` 등 다른 문자는 사용하지 않는다.
  - macOS와 Windows의 파일 시스템은 대소문자를 구분하지 않으므로, 대소문자만 다른 브랜치명은 충돌을 일으킨다.
  - 버전 표기에 쓰인 `.`도 `-`로 바꾼다. (`3.3` → `3-3`)
- 50자 제한은 prefix와 이슈 번호를 포함한 전체 길이에 적용한다.
- 작업명에는 핵심 키워드만 남기고 관사(a, an, the), be 동사, 불필요한 전치사는 생략한다.
- 작업명을 prefix와 같은 단어로 시작하지 않는다. (`fix/fix-login-error` → `fix/login-error`)
- update, change, modify, misc처럼 모호한 단어만으로 작성하지 않고, 작업 대상이 드러나도록 작성한다. (`feat/update` → `feat/add-coupon-expiry-notification`)
- 약어는 널리 통용되는 약어(api, db, ui, jwt 등)만 사용한다.

### 작성 예시

| 작업 설명 | 브랜치명 |
|---|---|
| 카카오 소셜 로그인 기능 추가 | `feat/add-kakao-social-login` |
| 이슈 #128, 쿠폰 만료 알림 기능 구현 | `feat/128-add-coupon-expiry-notification` |
| 주문 취소 시 발생하는 NullPointerException 수정 | `fix/order-cancel-null-pointer` |
| 결제 검증 로직을 별도 클래스로 분리 | `refactor/extract-payment-validator` |
| Spring Boot 3.3 버전 업그레이드 | `chore/upgrade-spring-boot-3-3` |
| API 명세 README 작성 | `docs/write-api-spec-readme` |
| 회원 서비스 단위 테스트 추가 | `test/add-member-service-unit-tests` |

## 실행 절차

1. 사용자가 설명한 작업 내용을 분석해 prefix를 결정한다.
2. 작업 내용을 영문 작업명으로 번역하고, 이슈 번호가 언급되었는지 확인한다.
3. 브랜치를 만들 Git 저장소 안에서 스크립트를 실행한다.
4. 종료 코드가 0이 아니면 아래의 "종료 코드별 대응" 표에 따라 처리한다.
5. 생성된 브랜치명, 기준 브랜치, 기준 커밋을 표준 에러로 출력된 경고와 함께 사용자에게 보고한다.

`git switch -c`, `git checkout -b` 같은 git 명령을 직접 실행해서 브랜치를 만들지 않는다. 스크립트가 실패하면 우회하지 말고, 원인을 해결하거나 사용자에게 보고한다.
사용자가 브랜치명을 먼저 확인하길 원하면 `--dry-run`으로 결과를 미리 보여 준다.

## 스크립트 사용법

스크립트는 이 SKILL.md가 있는 디렉터리를 기준으로 `scripts/create-branch.sh`에 있다. Claude Code에서는 `<스킬 디렉터리>` 자리에 `${CLAUDE_SKILL_DIR}`를 사용한다.

```bash
bash <스킬 디렉터리>/scripts/create-branch.sh <prefix> "<영문 작업명>" [옵션]

# 예시
bash <스킬 디렉터리>/scripts/create-branch.sh feat "add kakao social login"
bash <스킬 디렉터리>/scripts/create-branch.sh feat "add coupon expiry notification" --issue 128
```

| 옵션 | 설명 |
|---|---|
| `--issue <번호>` | 이슈 번호를 prefix 뒤에 붙인다. `#128`처럼 `#`을 붙여도 된다. |
| `--base <브랜치>` | 기준 브랜치를 지정한다. 생략하면 develop, dev, development 중 존재하는 브랜치를 사용한다. |
| `--remote <이름>` | 원격 저장소 이름을 지정한다. (기본값: `origin`) |
| `--no-fetch` | 원격 저장소에 접속하지 않고 마지막으로 fetch한 정보를 사용한다. |
| `--allow-dirty` | 커밋되지 않은 변경 사항을 새 브랜치로 가져간다. 사용자 승인이 필요하다. |
| `--allow-long` | 50자를 넘는 브랜치명을 허용한다. 사용자 승인이 필요하다. |
| `--allow-main-base` | main/master를 기준 브랜치로 허용한다. 사용자 승인이 필요하다. |
| `--dry-run` | 검증과 fetch까지만 수행하고 브랜치는 생성하지 않는다. |

- 작업명은 영문으로 전달한다. 대문자, 공백, 특수 문자는 스크립트가 규칙에 맞게 변환한다. (`"Upgrade Spring Boot 3.3"` → `upgrade-spring-boot-3-3`)
- 작업명에 prefix를 포함하지 않는다. (`"feat/add-login"` ✗ → `"add login"` ✓)

실행 결과는 표준 출력에 `key=value` 형식으로 출력되고, 진행 로그와 경고는 표준 에러에 출력된다.

```
RESULT=created
BRANCH=feat/add-kakao-social-login
BASE=origin/develop
BASE_COMMIT=3f2a9c1
CARRIED_CHANGES=false
```

- `RESULT`: 브랜치를 생성했으면 `created`, `--dry-run`으로 실행했으면 `dry-run`
- `CARRIED_CHANGES`: 커밋되지 않은 변경 사항을 새 브랜치로 가져왔는지 여부

## 종료 코드별 대응

| 코드 | 의미 | 대응 |
|---|---|---|
| 0 | 성공 | 결과와 경고를 사용자에게 보고한다. |
| 1 | 저장소 상태 오류 또는 git 명령 실패 | 오류 메시지를 사용자에게 보고한다. 진행 중인 rebase, merge 등의 작업은 임의로 중단하지 않는다. |
| 2 | 인자 오류 | 메시지에 맞게 prefix나 작업명을 고쳐 다시 실행한다. main/master 기준 오류는 사용자가 명시적으로 요청한 경우에만 `--allow-main-base`를 추가한다. |
| 3 | 브랜치명 50자 초과 | 핵심 키워드만 남겨 다시 실행한다. 줄이면 의미가 훼손될 때만 사용자 승인을 받고 `--allow-long`을 추가한다. |
| 4 | 커밋되지 않은 변경 사항 존재 | 변경 파일 목록을 보여 주고 처리 방법을 사용자에게 묻는다. (아래 주의 사항 참고) |
| 5 | 기준 브랜치 없음 또는 후보가 여러 개 | 사용자에게 기준 브랜치를 확인하고 `--base`로 지정한다. |
| 6 | 같은 이름의 브랜치가 이미 존재 | 다른 작업명을 제안하거나, 기존 브랜치를 이어서 사용할지 사용자에게 확인한다. |
| 7 | 원격 저장소 조회 또는 fetch 실패 | 네트워크와 인증 상태를 사용자에게 보고한다. 사용자가 동의하면 `--no-fetch`로 다시 실행한다. |

## 주의 사항

- 커밋되지 않은 변경 사항을 사용자 동의 없이 stash, reset, checkout, clean 하지 않는다. 변경 사항이 있으면 다음 선택지를 제시한다.
  - 변경 사항을 새 브랜치로 가져가기 (`--allow-dirty`)
  - 현재 브랜치에 먼저 커밋하기
  - stash로 보관한 뒤 새 브랜치 생성하기
- `git branch -D`, `git switch -C`, `git checkout -B`처럼 기존 브랜치를 삭제하거나 덮어쓰는 명령을 사용하지 않는다.
- `--allow-*` 옵션은 사용자가 해당 상황을 확인하고 승인한 경우에만 추가한다.
- 로컬 개발 브랜치에 원격 저장소에 없는 커밋이 있다는 경고가 나오면, 그 커밋이 새 브랜치에 포함되지 않았다는 사실을 사용자에게 알린다.
- 새 브랜치에는 upstream을 설정하지 않는다. 기준 브랜치(`origin/develop`)가 upstream으로 설정되면 push나 pull이 개발 브랜치를 대상으로 실행될 수 있기 때문이다.
