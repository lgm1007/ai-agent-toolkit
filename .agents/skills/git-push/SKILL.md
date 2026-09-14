---
name: git-push
description: 현재 브랜치를 같은 이름의 원격 브랜치로 push하고, 원격 브랜치가 로컬 커밋과 일치하는지, upstream이 설정되었는지 등 push 후 상태를 확인한다. 브랜치 push, 원격 저장소에 올리기, push 상태 확인을 요청받았을 때 사용한다.
---

# Git push

현재 브랜치를 같은 이름의 원격 브랜치로 push하고, push 후 원격 브랜치와의 동기화 상태를 확인한다.
사전 검증, push, 상태 확인은 반드시 `scripts/push.sh`로 수행해서, 누가 실행하더라도 같은 절차와 결과를 얻도록 한다.

## push 규칙

1. 현재 체크아웃된 브랜치만 push한다.
2. 원격 브랜치 이름은 로컬 브랜치 이름과 같게 한다. upstream이 없거나 다른 이름의 브랜치(예: `origin/develop`)로 설정되어 있으면, push 후 `<원격>/<현재 브랜치>`로 설정한다.
3. 강제 push는 하지 않는다. 원격 브랜치에 로컬에 없는 커밋이 있으면 push하지 않고 사용자에게 확인한다.
4. main, master, develop, dev, development 브랜치에 직접 push하는 것은 사용자가 명시적으로 요청한 경우에만 허용한다. 개발 브랜치에 작업을 반영할 때는 git-merge-to-target 스킬을 사용한다.
5. push할 커밋에 민감한 파일로 의심되는 파일이 있으면 push하지 않고 사용자에게 확인한다. 한 번 push한 파일은 나중에 지워도 원격 저장소의 이력에 남기 때문이다.
6. push가 끝나면 원격 브랜치가 로컬 HEAD와 같은 커밋을 가리키는지 확인한다.
7. 커밋하지 않은 변경 사항은 push에 포함되지 않으므로, 남아 있으면 사용자에게 알린다.

## 실행 절차

1. 사용자가 push를 요청했는지 확인한다. 커밋이나 다른 작업을 하는 도중에 임의로 push하지 않는다.
2. 스크립트를 실행한다. 사용자가 push 전에 확인하길 원하면 `--dry-run`으로 push될 커밋 목록을 먼저 보여 준다.
3. 종료 코드가 0이 아니면 아래의 "종료 코드별 대응" 표에 따라 처리한다.
4. 브랜치, 원격 브랜치, push한 커밋 수, 원격 커밋 해시를 사용자에게 보고한다. PR 생성 링크가 출력되었거나 커밋하지 않은 변경 사항 경고가 있으면 함께 알린다.

`git push`를 직접 실행하지 않는다. 스크립트가 실패하면 우회하지 말고, 원인을 해결하거나 사용자에게 보고한다.

## 스크립트 사용법

스크립트는 이 SKILL.md가 있는 디렉터리를 기준으로 `scripts/push.sh`에 있다. Claude Code에서는 `<스킬 디렉터리>` 자리에 `${CLAUDE_SKILL_DIR}`를 사용한다.

```bash
bash <스킬 디렉터리>/scripts/push.sh [옵션]

# 예시
bash <스킬 디렉터리>/scripts/push.sh --dry-run
bash <스킬 디렉터리>/scripts/push.sh
```

| 옵션 | 설명 |
|---|---|
| `--remote <이름>` | 원격 저장소 이름을 지정한다. 생략하면 upstream의 원격 저장소를 사용하고, upstream이 없으면 `origin`을 사용한다. |
| `--allow-protected` | main, master, develop, dev, development 브랜치의 직접 push를 허용한다. 사용자 승인이 필요하다. |
| `--allow-sensitive` | 민감한 파일로 의심되는 파일이 push할 커밋에 있어도 push한다. 사용자 승인이 필요하다. |
| `--dry-run` | 검증과 push 대상 확인까지만 수행하고 push하지 않는다. |

- 민감한 파일은 파일 이름으로 판별한다. (`.env`, `*.pem`, `*.key`, `id_rsa` 등, `.example`과 `.sample` 파일은 제외)
- 스크립트는 원격 브랜치 조회와 fetch, 사전 검증, push, upstream 설정, 원격 커밋 확인 순서로 동작한다.

실행 결과는 표준 출력에 `key=value` 형식으로 출력되고, 진행 로그, 경고, push할 커밋 목록은 표준 에러에 출력된다.

```
RESULT=pushed
BRANCH=feat/128-add-kakao-social-login
REMOTE=origin
UPSTREAM=origin/feat/128-add-kakao-social-login
COMMITS=3
NEW_BRANCH=true
HEAD_COMMIT=9c1e2f4
PR_URL=https://github.com/owner/repo/pull/new/feat/128-add-kakao-social-login
```

- `RESULT`: push와 상태 확인을 완료했으면 `pushed`, push할 커밋이 없으면 `up-to-date`, `--dry-run`으로 실행했으면 `dry-run`
- `UPSTREAM`: push 후 설정되는 upstream 브랜치
- `COMMITS`: 원격 브랜치에 새로 올라가는 커밋 수
- `NEW_BRANCH`: 원격 저장소에 브랜치를 새로 만드는 push인지 여부
- `PR_URL`: 원격 저장소가 push 결과로 안내한 PR(MR) 생성 링크 (없으면 빈 값)

## 종료 코드별 대응

| 코드 | 의미 | 대응 |
|---|---|---|
| 0 | 성공 | 결과와 경고를 사용자에게 보고한다. |
| 1 | 저장소 상태 오류 또는 git 명령 실패 | 오류 메시지를 보고한다. detached HEAD이거나 rebase, merge 등이 진행 중이면 사용자가 먼저 정리하도록 안내한다. |
| 2 | 인자 오류 | 옵션을 확인해 다시 실행한다. |
| 3 | 보호 브랜치에 직접 push | 작업 브랜치를 만들거나 git-merge-to-target 스킬로 반영할지 사용자에게 확인한다. 사용자가 직접 push를 원하면 `--allow-protected`를 추가한다. |
| 4 | 원격 저장소 없음 | 등록된 원격 저장소를 확인하고, 어느 원격 저장소에 push할지 사용자에게 확인한다. 원격 저장소를 임의로 추가하지 않는다. |
| 5 | 원격 브랜치에 로컬에 없는 커밋 존재 | push하지 않은 이유를 보고하고, 원격 변경 사항을 merge 방식(`git pull`)과 rebase 방식(`git pull --rebase`) 중 어떻게 가져올지 사용자에게 확인한다. |
| 6 | 민감한 파일로 의심되는 파일 포함 | 파일 목록과 해당 커밋을 보여 주고 사용자에게 확인한다. 이미 커밋된 파일을 빼려면 커밋 이력을 수정해야 하므로 사용자와 방법을 정한다. |
| 7 | 원격 조회 또는 push 실패 | 오류 메시지를 보고한다. pre-push 훅이 실패했으면 원인을 수정한 뒤 다시 실행하고, 브랜치 보호 규칙이나 권한 문제면 사용자에게 알린다. |
| 8 | push 후 상태 검증 실패 | 원격 브랜치와 로컬 HEAD의 커밋 해시를 보고하고, 다른 사람이 동시에 push했을 가능성을 사용자에게 알린다. |

## 주의 사항

- `--force`, `--force-with-lease`, `--no-verify`, `--all`, `--mirror`, `--tags` 옵션으로 push하지 않는다.
- rebase로 커밋 이력을 바꿔서 원격 브랜치와 어긋난 경우에는 강제 push가 필요하다. 이 스킬은 강제 push를 하지 않으므로, 상황을 설명하고 사용자가 직접 결정하도록 한다.
- 원격 브랜치를 가져오기 위해 `git pull`을 실행하는 것은 사용자가 방식을 정한 뒤에만 한다. 충돌이 나면 임의로 해결하지 않는다.
- 태그 push, 원격 브랜치 삭제, PR 생성은 이 스킬 범위에 포함되지 않는다.
