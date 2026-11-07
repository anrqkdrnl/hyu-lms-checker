#!/bin/bash
# 앱 빌드: ./build.sh            → build/LMS 체커.app
#         ./build.sh --install  → 빌드 후 /Applications 에 설치 (쓰기 권한 없으면 ~/Applications)
#         ./build.sh --zip      → 배포용 zip (build/LMSChecker.zip)
# 필요: Xcode (Command Line Tools만으로는 SwiftUI 매크로가 없어 빌드 실패)
set -e
cd "$(dirname "$0")"
VER="$(cat VERSION)"
app/build_bundle.sh "LMS 체커" LMSChecker io.github.anrqkdrnl.lmschecker LMSApp.swift graduationcap.fill 4F7BF7 2A3FB8 "$PWD/build" "$VER" >/dev/null
APP="build/LMS 체커.app"
echo "빌드 완료: $APP (v$VER)"
for a in "$@"; do
  if [ "$a" = "--install" ]; then
    DEST=/Applications; [ -w "$DEST" ] || { DEST="$HOME/Applications"; mkdir -p "$DEST"; }
    pkill -x LMSChecker 2>/dev/null || true
    rm -rf "$DEST/LMS 체커.app"; cp -R "$APP" "$DEST/"
    echo "설치 완료: $DEST/LMS 체커.app"
  fi
  if [ "$a" = "--zip" ]; then
    rm -f build/LMSChecker.zip
    ditto -c -k --keepParent "$APP" build/LMSChecker.zip
    echo "zip: build/LMSChecker.zip"
  fi
done
