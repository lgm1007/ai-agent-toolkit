---
name: git-merge-to-target
description: 현재 브랜치(또는 지정한 source 브랜치)의 커밋을 target 브랜치에 merge 커밋으로 병합하고, target 브랜치를 원격 저장소에 push한다. 작업 브랜치를 develop 같은 대상 브랜치에 직접 merge하고 push해 달라는 요청을 받았을 때 사용한다.
---

# 대상 브랜치에 merge 후 push

source 브랜치의 커밋을 target 브랜치에 merge하고, target 브랜치를 원격 저장소에 push한다.
브랜치 상태 확인, 충돌 검사, merge, push, 실패 시 복구는 반드시 `scripts/merge-to-target.sh`로 수행해서, 누가 실행하더라도 같은 절차로 병합되도록 한다.

## 인자

| 인자 | 필수 여부 | 설명 |
|---|---|---|
| `target_branch` | 필수 | merge 결과를 반영할 브랜치 (예: `develop`) |
| `source_branch` | 선택 | merge할 커밋이 있는 브랜치. 생략하면 현재 체크아웃된 브랜치를 사용한다. |

## merge 규칙

1. target 브랜치를 원격 저장소의 최신 상태로 맞춘 뒤 merge한다.
2. merge는 항상 merge 커밋을 만드는 방식(`--no-ff`)으로 수행하고, 커밋 메시지는 Git 기본 형식(`Merge branch 'feat/128-add-kakao-social-login' into develop`)을 사용한다.
3. 충돌이 예상되면 작업 트리를 변경하기 전에 중단한다. 스크립트는 충돌을 해결하지 않는다.
4. push는 target 브랜치에만 수행하며, 강제 push(`--force`, `--force-with-lease`)는 사용하지 않는다.
5. push에 실패하면 로컬 target 브랜치를 merge 이전 상태로 되돌린다. 원격에 반영되지 않은 merge 커밋이 로컬에 남지 않도록 하기 위해서다.
6. 작업이 끝나면 실행 전에 체크아웃되어 있던 브랜치로 돌아간다.
7. main/master를 target으로 하는 merge는 사용자가 명시적으로 요청한 경우에만 허용한다. 운영 브랜치는 PR로 병합하는 것을 원칙으로 한다.
8. merge가 끝나도 source 브랜치는 삭제하지 않는다.

## 실행 절차

1. 사용자 요청에서 target 브랜치와 source 브랜치를 확인한다. target 브랜치가 명확하지 않으면 사용자에게 질문한다.
2. `--dry-run`으로 실행해 merge될 커밋 목록과 충돌 여부를 확인한다.
3. source 브랜치, target 브랜치, merge될 커밋 목록을 사용자에게 보여 주고 실행 승인을 받는다.
4. 승인을 받으면 같은 인자에서 `--dry-run`만 빼고 실행한다.
5. 종료 코드가 0이 아니면 아래의 "종료 코드별 대응" 표에 따라 처리한다.
6. merge 커밋, push한 원격 브랜치, 복귀한 브랜치를 사용자에게 보고한다.

target 브랜치를 원격에 push하면 다른 팀원의 작업에 바로 영향을 주므로, 사용자 승인 없이 실행하지 않는다. 사용자가 확인 없이 바로 진행하라고 명시한 경우에만 2~3번을 생략한다.
`git merge`, `git push`를 직접 실행하지 않는다. 스크립트가 실패하면 우회하지 말고, 원인을 해결하거나 사용자에게 보고한다.

## 스크립트 사용법

스크립트는 이 SKILL.md가 있는 디렉터리를 기준으로 `scripts/merge-to-target.sh`에 있다. Claude Code에서는 `<스킬 디렉터리>` 자리에 `${CLAUDE_SKILL_DIR}`를 사용한다.

```bash
bash <스킬 디렉터리>/scripts/merge-to-target.sh <target_branch> [source_branch] [옵션]

# 예시: 현재 브랜치를 develop에 merge하고 push
bash <스킬 디렉터리>/scripts/merge-to-target.sh develop --dry-run
bash <스킬 디렉터리>/scripts/merge-to-target.sh develop

# 예시: 지정한 브랜치를 develop에 merge하고 push
bash <스킬 디렉터리>/scripts/merge-to-target.sh develop feat/128-add-kakao-social-login
```

| 옵션 | 설명 |
|---|---|
| `--remote <이름>` | 원격 저장소 이름을 지정한다. (기본값: `origin`) |
| `--allow-main` | main/master를 target 브랜치로 허용한다. 사용자 승인이 필요하다. |
| `--dry-run` | fetch, 검증, 충돌 사전 검사까지만 수행하고 merge와 push는 하지 않는다. |

- 브랜치 이름에 원격 이름을 붙여 전달해도(`origin/develop`) 브랜치 이름만 사용한다.
- 스크립트는 원격 브랜치 fetch, 브랜치 상태 검증, 충돌 사전 검사, target 체크아웃과 fast-forward, merge, push, 원래 브랜치로 복귀하는 순서로 동작한다.

실행 결과는 표준 출력에 `key=value` 형식으로 출력되고, 진행 로그, 경고, merge될 커밋 목록은 표준 에러에 출력된다.

```
RESULT=merged
SOURCE=feat/128-add-kakao-social-login
TARGET=develop
REMOTE=origin
COMMITS=3
MERGE_COMMIT=9c1e2f4
```

- `RESULT`: merge와 push를 완료했으면 `merged`, 이미 병합된 상태면 `up-to-date`, `--dry-run`으로 실행했으면 `dry-run`
- `COMMITS`: 이번 merge로 target 브랜치에 새로 반영되는 source 브랜치의 커밋 수
- `MERGE_COMMIT`: 생성한 merge 커밋의 해시 (`merged`가 아니면 빈 값)

## 종료 코드별 대응

| 코드 | 의미 | 대응 |
|---|---|---|
| 0 | 성공 | `dry-run`이면 커밋 목록을 보여 주고 승인을 받는다. `merged`나 `up-to-date`면 결과를 보고한다. |
| 1 | 저장소 상태 오류 또는 git 명령 실패 | 오류 메시지를 보고한다. 진행 중인 rebase, merge 등의 작업은 임의로 중단하지 않는다. |
| 2 | 인자 오류 | 브랜치 이름을 확인해 다시 실행한다. main/master 대상 오류는 사용자가 명시적으로 요청한 경우에만 `--allow-main`을 추가한다. |
| 3 | 커밋되지 않은 변경 사항 존재 | 변경 파일 목록을 보여 주고, 커밋(git-commit 스킬)과 stash 중 어떻게 처리할지 사용자에게 묻는다. |
| 4 | 브랜치 또는 원격 저장소 없음 | 브랜치 이름에 오타가 없는지 확인하고, 올바른 브랜치를 사용자에게 확인한다. target 브랜치를 원격에 새로 만들지 않는다. |
| 5 | 로컬과 원격 브랜치 상태 불일치 | 로컬 source 브랜치가 뒤처졌으면 pull할지, 로컬 target 브랜치에 push되지 않은 커밋이 있으면 그 커밋을 어떻게 처리할지 사용자에게 확인한다. |
| 6 | merge 충돌 예상 | 충돌 파일 목록을 보고한다. source 브랜치에 target 브랜치를 먼저 merge해 충돌을 해결한 뒤 다시 실행하도록 안내한다. |
| 7 | fetch 또는 push 실패 | 오류 메시지를 보고한다. 원격 저장소의 브랜치 보호 규칙 때문에 거부되었다면 PR로 병합하도록 안내한다. |

## 주의 사항

- `git push --force`, `git push --force-with-lease`, `git reset --hard`를 직접 실행하지 않는다.
- 충돌 파일을 임의로 수정하지 않는다. 사용자가 충돌 해결을 요청한 경우에만 source 브랜치에서 해결한다.
- 로컬 target 브랜치에 push되지 않은 커밋이 있으면 임의로 삭제하거나 되돌리지 않는다.
- 추적되지 않는 파일은 변경 사항 검사에서 제외한다. 다만 target 브랜치에 같은 경로의 파일이 있으면 브랜치 전환이 실패한다(종료 코드 1).
- merge 전에 테스트나 빌드 확인이 필요한 프로젝트라면, 실행 승인을 받을 때 먼저 확인할지 사용자에게 묻는다.
- source 브랜치 삭제와 PR 생성은 이 스킬 범위에 포함되지 않는다.
