# Mini Games

Godot로 만든 작은 웹 게임 카탈로그. `index.html`이 `games.json`을 읽어 카드 목록을 그린다.

## 구조
```
index.html            카탈로그 페이지
games.json            게임 목록 (slug, title, description, tags, controls, engine, added)
<slug>/               게임별 웹 빌드 (index.html, .wasm, .pck …) + cover.jpg + CREDITS.md
scripts/publish-godot.sh   Godot 프로젝트 → <slug>/ 로 내보내기
```

## 새 게임 추가
1. Godot 프로젝트에 **Web** export preset 추가 (Thread Support 끔, VRAM 압축 Desktop+Mobile)
2. `scripts/publish-godot.sh <프로젝트 경로> <slug>`
3. `<slug>/cover.jpg` (16:9) 추가, `games.json`에 항목 추가
4. commit & push → GitHub Pages가 자동 배포
