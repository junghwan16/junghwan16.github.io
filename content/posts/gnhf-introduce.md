---
title: "gnhf: 재워두고 돌리는 에이전트 루프"
url: "/backend/ai/2026/06/03/gnhf/introduce"
date: 2026-06-03 16:20:00 +0900
categories: [ai, agent]
draft: true
---

gnhf는 목표 하나를 던져두면 에이전트를 반복 실행하고, 성공한 지점마다 커밋을 남기는 CLI 도구다. 이름처럼 자기 전에 걸어두고 아침에 결과를 확인하는 사용성을 노린다.

ralph loop나 karpathy의 autoresearch 스타일을 CLI에서 설정을 덜 쓰고 돌릴 수 있게 만든 쪽에 가깝다. 개인적으로는 비슷한 루프 도구 중 설정 부담이 적어서 마음에 들었다.

---

## Quick Start

Git 레포지토리 루트에서 원하는 목표를 입력하면 된다. 기본 에이전트는 Claude다.

```bash
$ gnhf "reduce complexity of the codebase without changing functionality"
# have a good sleep

```

OpenAI Codex 등 다른 에이전트를 지정하려면 `--agent` 옵션을 사용한다. Claude Code, Codex, Rovo Dev, OpenCode, GitHub Copilot CLI 등을 지원한다.

```bash
$ gnhf --agent codex "..."

```

토큰 제한이나 루프 횟수에 안전장치를 걸고 싶다면 아래와 같이 옵션을 지정한다.

```bash
$ gnhf "reduce complexity of the codebase without changing functionality" \
    --max-iterations 10 \
    --max-tokens 5000000
# have a good nap

```

---

## 동작 방식

1. **점진적 커밋 및 롤백 (Incremental Commits)**
이터레이션이 성공하면 `gnhf <iteration>: <summary>` 형태로 자동 커밋을 생성한다. 실패하면 `git reset --hard`로 롤백하므로 중간에 끊기더라도 성공한 지점까지의 작업은 보존된다.
2. **실패 핸들링**
커밋 실패 시 작업을 보존한 채 다음 이터레이션에서 수정을 시도한다. 에이전트 에러는 지수 백오프(Exponential Backoff)로 재시도하며, 3회 연속 실패하거나 크레딧 부족 같은 하드 에러 발생 시 즉시 중단된다.
3. **공유 메모리 (`notes.md`)**
이전 루프의 기록을 `notes.md`에 누적하여 다음 이터레이션의 컨텍스트로 주입한다. 덕분에 작업의 흐름이 끊기지 않는다.
4. **로컬 메타데이터 격리**
모든 실행 로그와 상태는 `.gnhf/runs/`에 저장되며 자동으로 git 무시(`\.gitignore`) 처리된다.

---

## 고급 기능

### 1. 멀티 에이전트 병렬 작업 (`--worktree`)

`git worktree`를 활용해 격리된 디렉토리와 브랜치에서 여러 에이전트를 동시에 돌릴 수 있다. 백그라운드(`&`)로 실행해 두면 알아서 병렬 처리하며, 작업이 끝난 워크트리는 보존되므로 나중에 메인 브랜치로 체리픽하거나 머지하면 된다.

```bash
# Run multiple agents on the same repo simultaneously using worktrees
$gnhf --worktree "implement feature X" &$ gnhf --worktree "add tests for module Y" &
$ gnhf --worktree "refactor the API layer" &

```

### 2. 라이브 브랜치 모드 (`--current-branch --push`)

새 브랜치를 생성하지 않고 현재 작업 중인 브랜치에서 루프를 돌리며, 이터레이션 성공 시마다 원격 레포지토리에 자동으로 `git push`를 수행한다. 배포 파이프라인이나 실시간 모니터링 환경에 유용하다.

```bash
# Commit directly on the current branch and push after each successful iteration
$ gnhf --current-branch --push "keep improving this app"

```

---

## 설치 및 설정

npm을 통해 글로벌 설치가 가능하다. 실행 중 컴퓨터가 잠드는 것을 방지하는 `--prevent-sleep` 기능이 OS 네이티브로 작동한다.

```bash
npm install -g gnhf

```

세부 설정은 `~/.gnhf/config.yml`에서 관리하며 기본 에이전트 지정, 커스텀 바이너리 경로(`agentPathOverride`), 에이전트 CLI 인자 오버라이드(`agentArgsOverride`), Conventional Commit 스타일 적용(`preset: conventional`) 등이 가능하다.

---

## 한줄평

에이전트 로그를 실시간으로 붙잡고 있거나 밤새 켜두기 불안했던 개발자에게 필수적인 툴이다. 터미널 타이틀에 실시간 토큰 소모량과 진행 상황도 표시되어 편리하다. 다 던져두고 꿀잠 자러 가자. Good Night, Have Fun!
