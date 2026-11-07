#!/usr/bin/env python3
"""주차학습(LearningX) 읽기 전용 수집기. Playwright persistent context 사용.

  (기본)             저장된 세션 → 끊겼으면 키체인 hyu-lms-id/hyu-lms-pw로 자동 로그인
  --login            headful 창을 띄우고 사용자가 직접 로그인할 때까지 대기
  --fresh            빈 임시 프로필 + 쿠키 복원 없음 (세션 만료 상황 테스트용)
  --dump             결과를 xn_dump/last.json 에도 저장
  --courses 1,2,3    대상 과목 ID (기본: PRIORITY)

페이지 이동 + 로그인 폼 입력만 한다. 영상 클릭·재생·출석 조작 없음.
stdout 마지막 줄: {"ok": bool, "reason": str, "courses": {cid: modules JSON}}
"""
import json, os, subprocess, sys, getpass, tempfile, time
from playwright.sync_api import sync_playwright, TimeoutError as PWTimeout

BASE = "https://learning.hanyang.ac.kr"
DIR = os.path.expanduser("~/.lms_check")
PROFILE = os.path.join(DIR, "browser_profile")
DUMP = os.path.join(DIR, "xn_dump")
PRIORITY = ["211700", "209626"]
LOGIN = "--login" in sys.argv
FRESH = "--fresh" in sys.argv
DO_DUMP = "--dump" in sys.argv or LOGIN


def kc_get(service):
    r = subprocess.run(["security", "find-generic-password", "-a", getpass.getuser(),
                        "-s", service, "-w"], capture_output=True, text=True)
    return r.stdout.strip() if r.returncode == 0 else ""


def kc_set(service, value):
    subprocess.run(["security", "add-generic-password", "-U", "-a", getpass.getuser(),
                    "-s", service, "-w", value], capture_output=True)


def save_cookies(ctx):
    """세션 쿠키는 브라우저 종료 시 사라지므로 키체인에 보관."""
    cs = [c for c in ctx.cookies() if c["domain"].endswith("hanyang.ac.kr")]
    kc_set("hyu-lms-cookies", json.dumps(cs))


def load_cookies(ctx):
    raw = kc_get("hyu-lms-cookies")
    if raw:
        try:
            ctx.add_cookies(json.loads(raw))
        except Exception:
            pass


def xn_cookie(ctx):
    for c in ctx.cookies():
        if c["name"] == "xn_api_token" and c["value"]:
            return c["value"]
    return ""


def logged_in(page):
    try:
        page.goto(BASE + "/", wait_until="domcontentloaded", timeout=30000)
        page.wait_for_selector("#global_nav_profile_link, #uid", timeout=30000)
    except Exception:
        return False
    return page.url.startswith(BASE) and page.locator("#global_nav_profile_link").count() > 0


def auto_login(page):
    """키체인의 아이디/비번으로 SSO 로그인. 값은 출력·로그에 남기지 않는다.

    반환: "" 성공 / "no_credentials" / "auto_login_failed"(로그인 페이지가 거부 메시지를 띄움 = 재시도 무의미)
          / "login_timeout"(네트워크·잠자기 등 일시 오류 = 재시도 대상)
    """
    uid, upw = kc_get("hyu-lms-id"), kc_get("hyu-lms-pw")
    if not (uid and upw):
        return "no_credentials"
    dialogs = []

    def on_dialog(d):
        dialogs.append(d.message)
        try:
            d.dismiss()
        except Exception:
            pass

    page.on("dialog", on_dialog)
    try:
        for attempt in range(2):
            try:
                if page.locator("#uid").count() == 0:
                    page.goto(BASE + "/", wait_until="domcontentloaded", timeout=45000)
                page.wait_for_selector("#uid, #global_nav_profile_link", timeout=45000)
                if page.locator("#global_nav_profile_link").count() > 0:
                    return ""
                dialogs.clear()
                page.fill("#uid", uid)
                page.fill("#upw", upw)
                page.click("#login_btn")
                page.wait_for_selector("#global_nav_profile_link", timeout=60000)
                return ""
            except Exception as e:  # PWTimeout, net::ERR_* 등
                if dialogs:  # SSO가 alert로 거부 (비번 틀림/잠금 등) → 재시도하면 계정 잠길 수 있음
                    print(f"login rejected: {dialogs[-1][:100]}", file=sys.stderr)
                    shot(page, "login_fail")
                    return "auto_login_failed"
                print(f"login attempt {attempt + 1} error: {type(e).__name__}: {str(e)[:120]}", file=sys.stderr)
                if attempt == 0:
                    time.sleep(15)
                    try:
                        page.goto(BASE + "/", wait_until="domcontentloaded", timeout=45000)
                    except Exception:
                        pass
        shot(page, "login_timeout")
        return "login_timeout"
    finally:
        page.remove_listener("dialog", on_dialog)


def shot(page, name):
    """진단용 스크린샷 (입력값은 비밀번호 필드라 마스킹됨)."""
    try:
        os.makedirs(DUMP, exist_ok=True)
        page.screenshot(path=os.path.join(DUMP, f"{name}.png"))
        with open(os.path.join(DUMP, f"{name}.url"), "w") as f:
            f.write(page.url + "\n")
    except Exception:
        pass


def get_xn_token(page, ctx, cids):
    """주차학습 페이지를 한 번 열어 xn_api_token 쿠키를 받는다 (수명 2시간)."""
    for cid in [c for c in PRIORITY if c in cids] + [c for c in cids if c not in PRIORITY]:
        try:
            page.goto(f"{BASE}/courses/{cid}/external_tools/140", wait_until="domcontentloaded", timeout=45000)
        except PWTimeout:
            continue
        for _ in range(30):
            tok = xn_cookie(ctx)
            if tok:
                return tok
            time.sleep(1)
    return ""


def main():
    courses = PRIORITY
    if "--courses" in sys.argv:
        courses = [c for c in sys.argv[sys.argv.index("--courses") + 1].split(",") if c]
    out = {"ok": False, "reason": "", "courses": {}}
    profile = tempfile.mkdtemp() if FRESH else PROFILE
    with sync_playwright() as p:
        ctx = p.chromium.launch_persistent_context(profile, headless=not LOGIN, locale="ko-KR")
        try:
            if not (LOGIN or FRESH):
                load_cookies(ctx)
            page = ctx.pages[0] if ctx.pages else ctx.new_page()
            if LOGIN:
                page.goto(BASE + "/", wait_until="domcontentloaded")
                print("브라우저 창에서 직접 로그인해줘 (최대 5분 대기)…", file=sys.stderr)
                try:
                    page.wait_for_selector("#global_nav_profile_link", timeout=300000)
                except PWTimeout:
                    out["reason"] = "login_timeout"
                    return
                out["login"] = "manual"
            elif logged_in(page):
                out["login"] = "session"
            else:
                err = auto_login(page)
                if err:
                    out["reason"] = err
                    return
                out["login"] = "auto"

            xn = get_xn_token(page, ctx, courses)
            if not xn:
                out["reason"] = "no_xn_token"
                return
            for cid in courses:
                r = ctx.request.get(f"{BASE}/learningx/api/v1/courses/{cid}/modules",
                                    headers={"Authorization": f"Bearer {xn}"}, timeout=30000)
                if r.ok:
                    try:
                        out["courses"][cid] = r.json()
                    except Exception:
                        pass  # LearningX 안 쓰는 과목
            kc_set("hyu-lms-xn", xn)
            if not FRESH:
                save_cookies(ctx)
            out["ok"] = True
        except Exception as e:
            out["reason"] = f"{type(e).__name__}: {str(e)[:150]}"
        finally:
            ctx.close()
            if DO_DUMP:
                os.makedirs(DUMP, exist_ok=True)
                with open(os.path.join(DUMP, "last.json"), "w") as f:
                    json.dump(out, f, ensure_ascii=False, indent=1)
            print(json.dumps(out, ensure_ascii=False))


if __name__ == "__main__":
    main()
