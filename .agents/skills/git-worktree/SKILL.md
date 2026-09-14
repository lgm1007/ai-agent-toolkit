---
name: git-worktree
description: git-branch 스킬의 브랜치명 규칙에 따라 develop/dev 개발 브랜치에서 새 작업 브랜치를 만들고, 그 브랜치를 체크아웃한 독립 작업 디렉터리(worktree)를 저장소 루트의 .agents/worktree/ 아래에 생성한다. 현재 작업 디렉터리를 건드리지 않고 새 작업을 병행하거나, 브랜치별로 작업 공간을 분리해 달라는 요청을 받았을 때 사용한다.
---

# Git worktree 생성

git-branch 스킬과 같은 규칙으로 새 작업 브랜치를 만들고, 그 브랜치 전용 작업 디렉터리(worktree)를 생성한다.
브랜치명 검증, worktree 경로 결정, 생성은 반드시 `scripts/create-worktree.sh`로 수행해서, 누가 실행하더라도 같은 결과를 얻도록 한다.

## 생성 규칙

1. 브랜치명과 기준 브랜치는 git-branch 스킬 규칙을 그대로 따른다. 스크립트가 git-branch 스킬의 `scripts/create-branch.sh`로 검증하므로, git-branch 스킬이 같은 skills 디렉터리에 있어야 한다.
2. worktree는 저장소 루트(메인 작업 트리)의 `.agents/worktree/` 아래에 만든다. 디렉터리 이름은 브랜치명의 `/`를 `-`로 바꾼 이름이다. (`feat/128-add-kakao-social-login` → `.agents/worktree/feat-128-add-kakao-social-login`)
3. 다른 worktree 안에서 실행해도 worktree를 중첩해서 만들지 않고, 메인 작업 트리의 `.agents/worktree/` 아래에 만든다.
4. 현재 작업 디렉터리의 브랜치와 파일은 변경하지 않는다. 커밋되지 않은 변경 사항은 새 worktree로 옮겨지지 않는다.
5. `.agents/worktree/`가 메인 작업 트리에서 추적되지 않는 파일로 잡히지 않도록, 아직 무시 대상이 아니면 `.git/info/exclude`에 등록한다. 커밋 대상이 되는 `.gitignore`는 수정하지 않는다.
6. 같은 경로에 디렉터리가 이미 있으면 덮어쓰거나 삭제하지 않는다.
7. 새 브랜치에는 upstream을 설정하지 않는다. push는 worktree 경로에서 git-push 스킬로 수행한다.

## 브랜치명 규칙 요약

자세한 규칙과 예시는 git-branch 스킬의 SKILL.md(`../git-branch/SKILL.md`)를 따른다.

- 형식은 `<prefix>/<작업명>`이고, 이슈 번호가 있으면 `<prefix>/<이슈 번호>-<작업명>`이다.
- prefix는 feat, fix, refactor, chore, docs, test 중 작업의 주된 목적에 맞는 하나를 사용한다.
- 작업명은 작업 설명을 간단한 영문으로 번역해서 작성하고, 영문 소문자, 숫자, `-`만 사용한다.
- 브랜치명은 prefix를 포함해 가능하면 50자 이내로 작성한다.

## 실행 절차

1. 작업 내용을 분석해 prefix를 결정하고 작업명을 영문으로 번역한다. 이슈 번호가 언급되었는지도 확인한다.
2. 스크립트를 실행한다. 사용자가 브랜치명과 경로를 먼저 확인하길 원하면 `--dry-run`으로 미리 보여 준다.
3. 종료 코드가 0이 아니면 아래의 "종료 코드별 대응" 표에 따라 처리한다.
4. 브랜치명, 기준 브랜치, worktree 경로를 사용자에게 보고한다.
5. 이후 그 작업의 파일 수정과 git-commit, git-push 스킬 실행은 `WORKTREE_PATH` 안에서 수행한다.
6. 새 worktree에는 `.env` 같은 추적되지 않는 파일과 의존성 설치 결과가 없다. 실행이나 테스트에 필요하면 무엇을 준비할지 사용자에게 확인한다.

`git worktree add`, `git switch -c`를 직접 실행하지 않는다. 스크립트가 실패하면 우회하지 말고, 원인을 해결하거나 사용자에게 보고한다.

## 스크립트 사용법

스크립트는 이 SKILL.md가 있는 디렉터리를 기준으로 `scripts/create-worktree.sh`에 있다. Claude Code에서는 `<스킬 디렉터리>` 자리에 `${CLAUDE_SKILL_DIR}`를 사용한다.

```bash
bash <스킬 디렉터리>/scripts/create-worktree.sh <prefix> "<영문 작업명>" [옵션]

# 예시
bash <스킬 디렉터리>/scripts/create-worktree.sh feat "add kakao social login" --issue 128
```

| 옵션 | 설명 |
|---|---|
| `--issue <번호>` | 이슈 번호를 prefix 뒤에 붙인다. |
| `--base <브랜치>` | 기준 브랜치를 지정한다. 생략하면 develop, dev, development 중 존재하는 브랜치를 사용한다. |
| `--remote <이름>` | 원격 저장소 이름을 지정한다. (기본값: `origin`) |
| `--no-fetch` | 원격 저장소에 접속하지 않고 마지막으로 fetch한 정보를 사용한다. |
| `--allow-long` | 50자를 넘는 브랜치명을 허용한다. 사용자 승인이 필요하다. |
| `--allow-main-base` | main/master를 기준 브랜치로 허용한다. 사용자 승인이 필요하다. |
| `--dry-run` | 검증과 경로 확인까지만 수행하고 브랜치와 worktree는 만들지 않는다. |

- 옵션은 git-branch 스킬의 스크립트와 같다. 다만 worktree는 현재 작업 트리의 변경 사항을 가져가지 않으므로 `--allow-dirty` 옵션은 없다.

실행 결과는 표준 출력에 `key=value` 형식으로 출력되고, 진행 로그와 경고는 표준 에러에 출력된다.

```
RESULT=created
BRANCH=feat/128-add-kakao-social-login
BASE=origin/develop
BASE_COMMIT=3f2a9c1
WORKTREE_PATH=/path/to/repo/.agents/worktree/feat-128-add-kakao-social-login
```

- `RESULT`: worktree를 생성했으면 `created`, `--dry-run`으로 실행했으면 `dry-run`
- `WORKTREE_PATH`: 생성한(또는 생성할) worktree의 절대 경로

## 종료 코드별 대응

종료 코드 2, 3, 5, 6, 7은 git-branch 스킬의 종료 코드와 의미가 같다.

| 코드 | 의미 | 대응 |
|---|---|---|
| 0 | 성공 | 결과를 보고하고, 이후 작업은 `WORKTREE_PATH`에서 진행한다. |
| 1 | 저장소 상태 오류 또는 git 명령 실패 | 오류 메시지를 보고한다. git-branch 스킬의 스크립트를 찾을 수 없다는 오류면 git-branch 스킬을 함께 설치하도록 안내한다. |
| 2 | 인자 오류 | 메시지에 맞게 prefix나 작업명을 고쳐 다시 실행한다. main/master 기준 오류는 사용자가 명시적으로 요청한 경우에만 `--allow-main-base`를 추가한다. |
| 3 | 브랜치명 50자 초과 | 핵심 키워드만 남겨 다시 실행한다. 줄이면 의미가 훼손될 때만 사용자 승인을 받고 `--allow-long`을 추가한다. |
| 4 | worktree 경로가 이미 존재 | 기존 디렉터리가 있다는 사실을 알리고 어떻게 처리할지 사용자에게 확인한다. 임의로 삭제하지 않는다. |
| 5 | 기준 브랜치 없음 또는 후보가 여러 개 | 사용자에게 기준 브랜치를 확인하고 `--base`로 지정한다. |
| 6 | 같은 이름의 브랜치가 이미 존재 | 다른 작업명을 제안하거나, 기존 브랜치를 이어서 사용할지 사용자에게 확인한다. |
| 7 | 원격 저장소 조회 또는 fetch 실패 | 네트워크와 인증 상태를 보고한다. 사용자가 동의하면 `--no-fetch`로 다시 실행한다. |

## 주의 사항

- worktree 디렉터리를 `rm -rf`로 지우지 않는다. 사용자가 제거를 요청하면 `git worktree remove <경로>`를 사용하고, 커밋되지 않은 변경 사항 때문에 거부되면 `--force`를 붙이지 말고 사용자에게 알린다.
- 디렉터리가 이미 지워져서 `git worktree list`에 prunable로 남아 있으면, 사용자에게 확인한 뒤 `git worktree prune`을 실행한다.
- 한 브랜치는 동시에 하나의 worktree에만 체크아웃할 수 있다. 기존 브랜치로 worktree를 만드는 작업은 이 스킬 범위에 포함되지 않는다.
- worktree를 제거한 뒤 브랜치를 삭제하는 작업은 사용자가 요청한 경우에만 수행한다.
