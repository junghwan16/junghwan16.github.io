#!/usr/bin/env bash
# Godot 프로젝트를 웹으로 내보내서 이 카탈로그의 <slug>/ 폴더에 넣는다.
# 사용법: scripts/publish-godot.sh <godot 프로젝트 경로> <slug>
#   예)  scripts/publish-godot.sh ~/tilt-marble tilt-marble
# 필요: 프로젝트에 "Web" export preset (Threads 끔), Godot 웹 export 템플릿.
# 새 게임이면 games.json 에 항목을 추가하고 <slug>/cover.jpg (16:9) 를 넣어 주세요.
set -euo pipefail

PROJECT="${1:?godot project path}"
SLUG="${2:?slug}"
GODOT="${GODOT:-/Applications/Godot.app/Contents/MacOS/Godot}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/$SLUG"
TMP="$(mktemp -d)"

"$GODOT" --headless --path "$PROJECT" --export-release "Web" "$TMP/index.html"

mkdir -p "$OUT"
# 기존 커버 이미지는 남기고 빌드 파일만 교체
find "$OUT" -maxdepth 1 -type f ! -name 'cover.*' -delete
cp "$TMP"/* "$OUT"/
[ -f "$PROJECT/assets/CREDITS.md" ] && cp "$PROJECT/assets/CREDITS.md" "$OUT/CREDITS.md"
rm -rf "$TMP"

grep -q "\"slug\": \"$SLUG\"" "$ROOT/games.json" || echo "⚠️  games.json 에 \"$SLUG\" 항목을 추가하세요."
[ -f "$OUT/cover.jpg" ] || echo "⚠️  $SLUG/cover.jpg (16:9 스크린샷) 을 추가하세요."
echo "✅ $SLUG 빌드 완료 → git add -A && git commit && git push"
