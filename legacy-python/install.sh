#!/bin/bash
# 한양대 LMS 체커 설치 — 실행: ./install.sh
#   다시 실행해도 안전 (키체인 값·결과 유지)
#   ./install.sh --reset-login   키체인의 Canvas 토큰/포털 아이디·비번 다시 입력
#   ./install.sh --no-app        맥 앱 빌드 생략 (스크립트 + 자동 실행만)
set -e
cd "$(dirname "$0")"
D="$HOME/.lms_check"
LABEL="com.seongsu.lmscheck"
P="$HOME/Library/LaunchAgents/$LABEL.plist"
RESET=0; NOAPP=0
for a in "$@"; do
  [ "$a" = "--reset-login" ] && RESET=1
  [ "$a" = "--no-app" ] && NOAPP=1
done
mkdir -p "$D" "$HOME/Library/LaunchAgents"

echo "▶ 1/5 스크립트 설치 → $D"
cp checker/lms_check.py checker/lms_browser.py "$D/"
chmod +x "$D/lms_check.py" "$D/lms_browser.py"

echo "▶ 2/5 Playwright + Chromium 설치 (처음엔 1~2분)"
PY=/usr/bin/python3; [ -x "$PY" ] || PY="$(command -v python3)"
[ -x "$D/venv/bin/python" ] || "$PY" -m venv "$D/venv"
"$D/venv/bin/python" -m pip install -q --upgrade pip playwright
"$D/venv/bin/python" -m playwright install chromium

echo "▶ 3/5 로그인 정보 → macOS 키체인 (Enter로 건너뛰면 나중에 앱 설정에서 입력 가능)"
ask() {  # ask <service> <설명> <secret 여부>
  if [ $RESET = 1 ] || ! security find-generic-password -a "$USER" -s "$1" >/dev/null 2>&1; then
    if [ "$3" = 1 ]; then read -r -s -p "  $2: " V; echo; else read -r -p "  $2: " V; fi
    [ -n "$V" ] && security add-generic-password -U -a "$USER" -s "$1" -w "$V" && echo "    저장됨"
  else
    echo "  $2 — 이미 저장돼 있음"
  fi
}
ask hyu-lms     "Canvas 액세스 토큰 (LMS → 계정 → 설정 → 새 액세스 토큰)" 1
ask hyu-lms-id  "한양 포털 아이디" 0
ask hyu-lms-pw  "한양 포털 비밀번호 (화면에 안 보임)" 1

echo "▶ 4/5 자동 실행 등록 (launchd: 10분마다 깨어나서 하루 1번만 실제 확인)"
cat > "$P" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array>
    <string>$D/venv/bin/python</string><string>$D/lms_check.py</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>StartInterval</key><integer>600</integer>
  <key>StandardErrorPath</key><string>$D/error.log</string>
</dict></plist>
PL
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$P"

echo "▶ 5/5 (맥 앱은 v2부터 저장소 루트 README 참고 — 이 레거시 버전에는 포함 안 함)"

echo
echo "✅ 완료. 매일 05시 이후 맥을 처음 깨울 때 1번 확인해서 팝업으로 알려줘."
echo "   앱: /Applications/LMS 체커.app   |   터미널: ~/.lms_check/venv/bin/python ~/.lms_check/lms_check.py --force"
