# Mini Games

Godot / Unity로 만든 작은 웹 게임 카탈로그. `index.html`이 `games.json`을 읽어 카드 목록을 그린다.

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

## Unity 게임 추가 (예: voxel-reveal)
1. 프로젝트에서 WebGL 빌드 (압축 끔 — GitHub Pages는 사전 압축 파일을 제대로 서빙하지 못함)
   `Unity -batchmode -quit -projectPath <프로젝트> -buildTarget WebGL -executeMethod VoxelReveal.Editor.BuildScript.BuildWebGL -buildPath <출력>`
2. 출력(index.html, Build/)을 `<slug>/`에 복사, `cover.jpg`·`CREDITS.md` 추가, `games.json`에 항목 추가

