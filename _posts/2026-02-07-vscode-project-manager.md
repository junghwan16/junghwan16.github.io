---
layout: single
title: "VSCode Project Manager로 워크스페이스 간 빠른 이동하기"
date: 2026-02-07 12:00:00 +0900
categories: [tools, vscode]
---

레포지토리가 늘어나고 AI 도구의 발전으로 컨텍스트 스위칭이 빈번해지면서 피로감이 커졌다. VSCode는 워크스페이스 간 빠른 이동을 위한 기본 단축키를 제공하지 않아 대안이 필요했다.

## Project Manager 익스텐션

**Project Manager** 익스텐션을 통해 `⌥ + ⌘ + P` 단축키로 프로젝트 간 빠르게 이동할 수 있다. 예전 버전에 비해 성능도 많이 개선되었다.

## 설정 방법

Git 프로젝트를 자동으로 감지하여 프로젝트 목록에 추가할 수 있다:

1. VSCode 설정 열기 (`⌘ + ,`)
2. `Project Manager: Git Base Folders` 검색
3. `Add Item` 클릭 후 Git 프로젝트들이 있는 상위 폴더 경로 입력
   - 예: `~/workspace`, `~/study`, `~/Documents`

## 3줄 요약

- Project Manager 익스텐션으로 `⌥ + ⌘ + P`로 워크스페이스 간 빠른 이동 가능
- Git Base Folders 설정으로 Git 프로젝트를 자동으로 감지하여 프로젝트 목록에 추가
- 수동으로 프로젝트를 추가할 필요 없이 상위 폴더만 지정하면 됨

---

## 참고자료

- [VS Marketplace - Project Manager](https://marketplace.visualstudio.com/items?itemName=alefragnani.project-manager) — 익스텐션 설치 및 상세 설정 가이드
