# 한양대 LMS 체커 (hyu-lms-checker)

한양대 LMS(learning.hanyang.ac.kr, Canvas 기반)에서 **안 들은 사이버강의, 미제출 과제, 7일 안에 마감되는 할 일**을 자동으로 모아 보여주는 macOS 도구.

- 매일 아침 맥을 처음 깨울 때 **자동으로 한 번 확인**하고 결과를 팝업으로 띄워 줘.
- **맥 앱(LMS 체커.app)**으로 결과를 보고, 바로 다시 확인하고, 설정을 바꿀 수 있어. 터미널은 안 써도 돼.
- **읽기 전용**이야. 영상 재생, 출석 처리, 과제 제출처럼 LMS 상태를 바꾸는 동작은 하지 않아.
- 아이디, 비밀번호, 토큰은 **macOS 키체인에만** 저장돼. 평문 파일에는 남기지 않아.

---

## 목차

1. [미리보기](#미리보기)
2. [요구 사항](#요구-사항)
3. [설치](#설치)
4. [사용법 — 맥 앱](#사용법--맥-앱)
5. [사용법 — 자동 실행 / 팝업](#사용법--자동-실행--팝업)
6. [사용법 — 터미널](#사용법--터미널)
7. [동작 원리](#동작-원리)
8. [파일 위치](#파일-위치)
9. [문제 해결](#문제-해결)
10. [업데이트 / 삭제](#업데이트--삭제)
11. [프로젝트 구조](#프로젝트-구조)

---

## 미리보기

앱 화면은 세 섹션으로 나뉘어 있어.

```
LMS 체커                         마지막 확인 11/7(토) 13:18 · 5초 전   [⟳ 지금 확인] [⚙]
─────────────────────────────────────────────────────────────────────
🎬 미수강 강의 12
   [학습하기] 10-1) 원가산정의 목적과 종류                         D-4
   테크노경영학(스타트업종합설계) · 10주차 / Unit-10         11/11(수) 23:59
   ...
📌 7일 내 할 일 1
   [완성하기] 10주차: 핵심정리노트                                 D-4
   과제 · 테크노경영학(스타트업종합설계)                      11/11(수) 23:59
```

- 마감까지 **24시간이 안 남은** 항목은 🔥와 빨간색으로, **2일 이내**인 항목은 주황색으로 표시돼.
- 항목을 클릭하면 LMS의 해당 페이지(주차학습 / 과제)가 브라우저로 열려.
- 마감 후 지각 인정 기간에 들어간 강의에는 `지각 인정` 배지가 붙어.

---

## 요구 사항

| 항목 | 내용 |
|---|---|
| macOS | 14 (Sonoma) 이상 |
| Python | 3.9 이상 (`/usr/bin/python3` 또는 python.org 설치본) |
| Xcode | **맥 앱을 빌드할 때만** 필요해. App Store에서 설치하고 한 번 실행해서 라이선스에 동의해 둬. Command Line Tools만 있으면 SwiftUI 매크로가 없어서 빌드가 실패해. |
| 계정 | 한양대 포털 아이디/비밀번호, Canvas 액세스 토큰 |

### Canvas 액세스 토큰 발급

1. https://learning.hanyang.ac.kr 에 로그인해.
2. 왼쪽 메뉴에서 **계정 → 설정**으로 들어가.
3. 아래쪽의 **승인된 통합 → `+ 새 액세스 토큰`**을 눌러. 용도는 아무거나 적고 만료일은 비워 둬.
4. 생성된 토큰을 복사해. 이 화면을 닫으면 다시 볼 수 없어.

---

## 설치

```bash
git clone https://github.com/anrqkdrnl/hyu-lms-checker.git
cd hyu-lms-checker
./install.sh
```

설치 스크립트는 아래 다섯 단계를 순서대로 진행해. 다시 실행해도 안전하고, 이미 저장된 키체인 값과 결과는 그대로 남아.

1. **스크립트 복사**: `checker/*.py`를 `~/.lms_check/`에 복사해.
2. **Playwright + Chromium 설치**: `~/.lms_check/venv` 가상환경을 만들어. 처음에는 1~2분 걸려.
3. **키체인 저장**: 아래 세 값을 물어봐. Enter로 건너뛰면 나중에 앱 설정에서 넣을 수 있어.
   - Canvas 액세스 토큰 → `hyu-lms`
   - 포털 아이디 → `hyu-lms-id`
   - 포털 비밀번호 → `hyu-lms-pw` (입력해도 화면에 안 보여)
4. **자동 실행 등록**: `~/Library/LaunchAgents/com.seongsu.lmscheck.plist`를 만들어.
5. **맥 앱 빌드**: `/Applications/LMS 체커.app`에 설치해. `/Applications`에 쓰기 권한이 없으면 `~/Applications`에 설치돼.

옵션:

```bash
./install.sh --reset-login   # 키체인 값(토큰/아이디/비번)을 다시 입력
./install.sh --no-app        # 맥 앱 없이 스크립트 + 자동 실행만 설치
./build_app.sh               # 맥 앱만 다시 빌드 (앱 코드를 고친 뒤)
```

### 처음 앱을 열 때

직접 빌드한 앱이라 Apple 공증이 없어서 **"확인되지 않은 개발자"** 경고가 뜰 수 있어. 그럴 땐 Finder에서 앱을 **우클릭 → 열기 → 열기**를 한 번만 해 주면 다음부터는 그냥 열려.

---

## 사용법 — 맥 앱

Spotlight(⌘Space)에서 `LMS 체커`를 검색하거나 Launchpad에서 실행해.

| 동작 | 방법 |
|---|---|
| 지금 다시 확인 | **지금 확인** 버튼 또는 **⌘R**. 보통 5초~1분 걸리고, 자동 로그인이 필요하면 1~2분 걸려. 실행 중에는 경과 시간이 보여. |
| LMS에서 열기 | 항목 클릭 |
| 설정 | 오른쪽 위 ⚙ 또는 **⌘,** |
| 종료 | 창을 닫으면 앱도 종료돼 |

아침 자동 실행 결과는 앱을 열거나 앱 창으로 돌아올 때 자동으로 반영돼.

### 설정 화면

- **한양 포털 계정**: 강의 목록을 가져올 때 자동 로그인에 쓰는 아이디와 비밀번호야. 비밀번호를 저장하면 "저장됨"으로만 표시되고 화면에 다시 불러오지 않아.
- **Canvas API 토큰**: 토큰을 새로 발급받았을 때만 입력해.
- **브라우저 창 띄워서 직접 로그인**: 자동 로그인이 계속 실패할 때 써. Chromium 창이 뜨면 직접 로그인해 줘. 5분까지 기다리고, 로그인한 세션은 저장돼.
- **자동 확인 켜기/끄기**: launchd 자동 실행을 등록하거나 해제해.
- **오류 로그 열기 / 데이터 폴더 열기**

---

## 사용법 — 자동 실행 / 팝업

- launchd가 10분마다 스크립트를 깨우지만, 실제 확인은 **하루 1번**만 해. 05시 이후 처음 깨어났을 때 성공하면 그날은 끝이야.
- 결과는 팝업으로 떠. 팝업 제목은 `LMS: 강의 N · 미제출 N · 오늘/내일 마감 N · 7일 내 N` 형식이야.
  - **자세히**를 누르면 LMS 체커 앱이 열려. 앱이 없으면 텍스트 파일이 열려.
- 네트워크가 잠깐 끊겼거나 막 깨어난 직후처럼 **일시적인 오류**가 나면 오늘 확인을 끝낸 것으로 치지 않고 10분 뒤에 다시 시도해. 3번째 시도에서도 실패하면 그때는 오류 내용을 팝업으로 보여줘.
- 비밀번호가 틀렸거나 계정이 잠긴 것처럼 **다시 시도해도 소용없는 오류**는 바로 팝업으로 알려줘. 계정 잠금을 피하려고 이 경우에는 재시도하지 않아.

---

## 사용법 — 터미널

앱 없이도 모든 기능을 쓸 수 있어.

```bash
PY=~/.lms_check/venv/bin/python
$PY ~/.lms_check/lms_check.py --force              # 지금 확인 + 팝업
$PY ~/.lms_check/lms_check.py --force --no-popup   # 지금 확인, 팝업 없이 latest.json만 갱신
$PY ~/.lms_check/lms_check.py --login              # 브라우저 창에서 직접 로그인 (세션 저장)
$PY ~/.lms_check/lms_browser.py --dump --courses 209626   # 강의 원본 JSON 덤프 (디버그용)
```

| 플래그 | 의미 |
|---|---|
| (없음) | launchd용. 하루 1번 가드를 적용해 |
| `--force` | 가드를 무시하고 지금 바로 실행 |
| `--no-popup` | 팝업 없이 결과 파일만 갱신하고, 실패하면 exit 1을 반환해 (앱이 이걸 써) |
| `--login` | headful 브라우저로 직접 로그인 |

---

## 동작 원리

```
launchd (10분마다)  ──┐
LMS 체커.app (버튼) ──┴─▶ lms_check.py
                           ├─ Canvas REST API (curl + 액세스 토큰)
                           │    ├ /api/v1/planner/items          → 7일 내 할 일 (제출/완료한 건 제외)
                           │    ├ /api/v1/users/self/missing_submissions → 미제출
                           │    └ /api/v1/courses                → 수강 과목 목록
                           └─ lms_browser.py (Playwright, headless Chromium)
                                1. 키체인의 세션 쿠키 복원
                                2. 세션이 끊겼으면 키체인 아이디/비번으로 SSO 자동 로그인
                                3. 주차학습 페이지를 한 번 열어 xn_api_token(수명 2시간)을 받음
                                4. /learningx/api/v1/courses/{id}/modules → 강의 목록
                           ▼
                 latest.json (앱이 읽음) · latest.txt · 팝업
```

- 사이버강의는 Canvas API에 마감 정보가 없고 LearningX(주차학습)에만 있어. 그래서 브라우저로 토큰을 받아 와야 해.
- 강의는 **출결 대상**이고 **아직 완료하지 않았고**, **출석 기간(open)이나 지각 기간(late)**인 것만 보여줘. 아직 열리지 않은 강의와 이미 마감된 강의는 빼.
- 강의 조회만 실패하면 과제와 마감 목록은 그대로 보여주고, 강의 섹션에만 실패 사유를 표시해.
- `PRIORITY_COURSES`(`lms_check.py` 상단)에 넣은 과목은 마감 시각이 같을 때 목록 앞쪽에 와. 본인 과목 ID로 바꿔서 써. 과목 ID는 LMS 과목 URL `/courses/<ID>`에 있는 숫자야.

---

## 파일 위치

| 경로 | 내용 |
|---|---|
| `~/.lms_check/lms_check.py`, `lms_browser.py` | 설치된 스크립트 |
| `~/.lms_check/venv/` | Python 가상환경 (Playwright) |
| `~/.lms_check/browser_profile/` | 브라우저 프로필 |
| `~/.lms_check/latest.json` | 최근 결과 (앱이 읽어) |
| `~/.lms_check/latest.txt` | 최근 결과 (텍스트) |
| `~/.lms_check/last_run` | 마지막으로 성공한 날짜 (하루 1번 가드) |
| `~/.lms_check/error.log` | 오류 로그 |
| `~/.lms_check/xn_dump/` | 로그인 실패 때 남는 진단 스크린샷 |
| `~/Library/LaunchAgents/com.seongsu.lmscheck.plist` | 자동 실행 설정 |
| 키체인 `hyu-lms` / `hyu-lms-id` / `hyu-lms-pw` | Canvas 토큰 / 포털 아이디 / 비밀번호 |
| 키체인 `hyu-lms-cookies` / `hyu-lms-xn` | 로그인 세션 쿠키 / LearningX 토큰 (자동 관리) |

키체인 값은 **키체인 접근.app**에서 이름으로 검색하면 확인하거나 지울 수 있어.

---

## 문제 해결

**강의 조회 실패: 로그인 거부됨**
비밀번호가 바뀌었거나 계정이 잠겼을 가능성이 커. 앱 설정에서 비밀번호를 다시 저장한 다음 **지금 확인**을 눌러 봐. 그래도 안 되면 **브라우저 창 띄워서 직접 로그인**을 써.

**강의 조회 실패: 로그인 페이지 응답 없음**
네트워크 문제나 잠자기 때문에 생기는 일시적인 오류야. 자동으로 다시 시도해. 계속 이러면 `~/.lms_check/xn_dump/login_timeout.png` 스크린샷을 확인해 봐.

**LMS 접속 실패 / 401**
Canvas 토큰이 만료됐거나 삭제됐을 수 있어. 새로 발급받아서 앱 설정에 저장해.

**아침에 팝업이 안 떠**
- 앱 설정에서 **자동 확인**이 켜져 있는지 봐. 터미널에서는 `launchctl list | grep lmscheck`로 확인할 수 있어.
- `~/.lms_check/last_run`에 오늘 날짜가 들어 있으면 오늘은 이미 확인한 거야.
- `~/.lms_check/error.log`를 확인해.

**앱 빌드 실패: `external macro implementation type 'SwiftUIMacros.StateMacro' could not be found`**
Command Line Tools로 빌드하려고 해서 생기는 오류야. Xcode를 설치하면 `build_app.sh`가 알아서 Xcode 툴체인을 써.

**앱 빌드 실패: `resource fork, Finder information, or similar detritus not allowed`**
`build_app.sh`가 서명 전에 `xattr -cr`를 실행하니까 최신 버전으로 다시 빌드해 봐.

**"확인되지 않은 개발자"**
Finder에서 앱을 우클릭 → 열기를 한 번 해 줘.

---

## 업데이트 / 삭제

업데이트:

```bash
cd hyu-lms-checker && git pull && ./install.sh
```

삭제:

```bash
launchctl bootout gui/$(id -u)/com.seongsu.lmscheck
rm ~/Library/LaunchAgents/com.seongsu.lmscheck.plist
rm -rf ~/.lms_check "/Applications/LMS 체커.app"
for s in hyu-lms hyu-lms-id hyu-lms-pw hyu-lms-cookies hyu-lms-xn; do
  security delete-generic-password -a "$USER" -s "$s" 2>/dev/null
done
```

---

## 프로젝트 구조

```
hyu-lms-checker/
├── install.sh            # 전체 설치 (스크립트 · venv · 키체인 · launchd · 앱)
├── build_app.sh          # 맥 앱만 빌드해서 /Applications에 설치
├── checker/
│   ├── lms_check.py      # 본체: Canvas API 조회, 결과 정리, 팝업, latest.json
│   └── lms_browser.py    # Playwright 수집기: 세션 복원 → 자동 로그인 → LearningX 강의 목록
└── app/
    ├── LMSApp.swift      # SwiftUI 앱 (목록 화면, 설정 화면)
    ├── Shared.swift      # 프로세스 실행, 키체인, launchd, 날짜 포맷, 공용 뷰
    └── make_icon.swift   # SF Symbol로 앱 아이콘 생성
```

앱은 Xcode 프로젝트 없이 `swiftc`로 바로 빌드해. 앱 자체에는 LMS 로직이 없어. Python 스크립트를 `--force --no-popup`으로 실행하고 `latest.json`을 읽어서 보여주기만 해. 그래서 자동 실행과 앱이 항상 같은 결과를 보여줘.

## 주의

- 개인용 비공식 도구라서 학교와는 관련이 없어. LMS 페이지 구조나 API가 바뀌면 동작하지 않을 수 있어.
- 조회만 해. 강의를 재생하거나 출석을 조작하는 기능은 넣지 않아.
