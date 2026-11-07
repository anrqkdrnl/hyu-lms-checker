#!/usr/bin/env python3
"""한양대 LMS(Canvas) 마감/미제출 체크 → macOS 팝업."""
import json, os, re, subprocess, sys, time, getpass
from datetime import datetime, timedelta, timezone

BASE = "https://learning.hanyang.ac.kr"
DIR = os.path.expanduser("~/.lms_check")
STATE = os.path.join(DIR, "last_run")
OUT = os.path.join(DIR, "latest.txt")
FAILS = os.path.join(DIR, "lecture_fails")
VENV_PY = os.path.join(DIR, "venv/bin/python")
BROWSER = os.path.join(DIR, "lms_browser.py")
DAYS = 7
FORCE = "--force" in sys.argv
NO_POPUP = "--no-popup" in sys.argv  # 앱에서 실행할 때: 팝업 없이 latest.json만 갱신
JSON_OUT = os.path.join(DIR, "latest.json")
APP_NAME = "LMS 체커"
KST = timezone(timedelta(hours=9))
PRIORITY_COURSES = ["209626", "211700"]  # AI+X:머신러닝, 테크노경영학 — 강의 목록에서 먼저 표시
VIDEO_TYPES = {"mp4", "movie", "screenlecture"}
FATAL = {  # 재시도해도 안 되는 오류 → 바로 팝업으로 안내
    "no_credentials": "키체인에 아이디/비번 없음 (hyu-lms-id / hyu-lms-pw)",
    "auto_login_failed": "로그인 거부됨 (비번 변경/잠금?) → 키체인 hyu-lms-pw 갱신 또는 python3 ~/.lms_check/lms_check.py --login",
}
TRANSIENT_MSG = {  # 재시도 후에도 실패하면 보여줄 문구
    "login_timeout": "로그인 페이지 응답 없음 (네트워크/잠자기?) — 다음 주기에 자동 재시도됨",
}


def token(service="hyu-lms"):
    return subprocess.run(
        ["security", "find-generic-password", "-a", getpass.getuser(), "-s", service, "-w"],
        capture_output=True, text=True, check=True).stdout.strip()


def get(path, tok):
    r = subprocess.run(
        ["curl", "-sS", "--fail", "--max-time", "20",
         "-H", f"Authorization: Bearer {tok}", BASE + path],
        capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(r.stderr.strip() or f"curl exit {r.returncode}")
    return json.loads(r.stdout)


def parse_dt(s):
    if not s:
        return None
    return datetime.fromisoformat(s.replace("Z", "+00:00")).astimezone(KST)


def abs_url(u):
    if not u:
        return ""
    return u if u.startswith("http") else BASE + u


def fmt_due(dt, now):
    if dt is None:
        return "마감 없음"
    d = (dt.date() - now.date()).days
    tag = "오늘" if d == 0 else "내일" if d == 1 else f"D-{d}" if d > 0 else f"{-d}일 지남"
    wd = "월화수목금토일"[dt.weekday()]
    return f"{dt:%m/%d}({wd}) {dt:%H:%M} [{tag}]"


def collect(tok, now):
    start = now.date().isoformat()
    end = (now + timedelta(days=DAYS)).date().isoformat()
    items = get(f"/api/v1/planner/items?start_date={start}&end_date={end}&per_page=100", tok)
    upcoming = []
    for it in items:
        if (it.get("planner_override") or {}).get("marked_complete"):
            continue
        sub = it.get("submissions")
        if isinstance(sub, dict) and (sub.get("submitted") or sub.get("graded")):
            continue
        p = it.get("plannable") or {}
        upcoming.append({
            "course": re.sub(r"^\d+HY\d+_", "", it.get("context_name") or ""),
            "title": p.get("title") or p.get("name") or "(제목 없음)",
            "type": it.get("plannable_type", ""),
            "due": parse_dt(it.get("plannable_date") or p.get("due_at")),
            "url": abs_url(it.get("html_url")),
        })
    upcoming.sort(key=lambda x: x["due"] or now + timedelta(days=999))

    missing = []
    try:
        for a in get("/api/v1/users/self/missing_submissions?include[]=course&per_page=100", tok):
            missing.append({
                "course": re.sub(r"^\d+HY\d+_", "", (a.get("course") or {}).get("name", "")),
                "title": a.get("name", ""),
                "due": parse_dt(a.get("due_at")),
                "url": abs_url(a.get("html_url")),
            })
    except Exception:
        pass  # 학교가 막아놨으면 생략
    return upcoming, missing


def course_ids(tok):
    cs = get("/api/v1/courses?enrollment_state=active&per_page=100", tok)
    ids = [str(c["id"]) for c in cs if c.get("id")]
    return sorted(ids, key=lambda i: (i not in PRIORITY_COURSES, i)), {str(c["id"]): re.sub(r"^\d+HY\d+_", "", c.get("name", "")) for c in cs}


def fetch_modules(cids):
    """{cid: modules JSON}. 백그라운드(headless) 브라우저로 주차학습 페이지를 열어 가져온다."""
    r = subprocess.run([VENV_PY, BROWSER, "--courses", ",".join(cids)],
                       capture_output=True, text=True, timeout=600)
    lines = r.stdout.strip().splitlines()
    if not lines:
        raise RuntimeError(f"browser_crash: {r.stderr.strip()[-150:]}")
    out = json.loads(lines[-1])
    if not out["ok"]:
        raise RuntimeError(out["reason"])
    return out["courses"]


def lectures(tok, now):
    """미수강 출결 대상 영상. 출석 기간(open) 또는 지각 기간(late)인 것만."""
    cids, names = course_ids(tok)
    res = []
    for cid, mods in fetch_modules(cids).items():
        for m in mods:
            for it in m.get("module_items", []):
                cd = it.get("content_data") or {}
                kind = (cd.get("item_content_data") or {}).get("content_type")
                if it.get("content_type") != "attendance_item" or kind not in VIDEO_TYPES:
                    continue
                if not cd.get("use_attendance") or it.get("completed"):
                    continue
                st = cd.get("lecture_period_status")
                if st == "open":
                    due, late = parse_dt(cd.get("due_at")), False
                elif st == "late":
                    due, late = parse_dt(cd.get("late_at") or cd.get("lock_at")), True
                else:
                    continue  # not_open(예정), late_after(마감됨)
                res.append({"course": names.get(cid, cid), "cid": cid, "week": m.get("title", ""),
                            "title": it.get("title", ""), "due": due, "late": late})
    res.sort(key=lambda x: (x["due"] or now + timedelta(days=999), x["cid"] not in PRIORITY_COURSES))
    return res


TYPE_KO = {"assignment": "과제", "quiz": "퀴즈", "discussion_topic": "토론",
           "wiki_page": "페이지", "calendar_event": "일정", "planner_note": "메모"}


def render(upcoming, missing, lecs, lec_err, now):
    lines = [f"[{now:%Y-%m-%d %H:%M}] LMS 체크", ""]
    if lec_err:
        lines.append(f"🎬 강의 조회 실패: {lec_err}")
        lines.append("")
    else:
        lines.append(f"🎬 미수강 강의 {len(lecs)}건")
        for l in lecs:
            fire = "🔥" if l["due"] and l["due"] - now <= timedelta(hours=24) else ""
            late = " (지각 인정 마감)" if l["late"] else ""
            lines.append(f"  • {fire}{fmt_due(l['due'], now)}{late} | {l['course']} | {l['title']}")
        if not lecs:
            lines.append("  다 들었음 👍")
        lines.append("")
    if missing:
        lines.append(f"⚠️ 미제출(마감 지남) {len(missing)}건")
        for m in missing:
            lines.append(f"  • {m['course']} | {m['title']} — {fmt_due(m['due'], now)}")
        lines.append("")
    lines.append(f"📌 {DAYS}일 내 할 일 {len(upcoming)}건")
    for u in upcoming:
        t = TYPE_KO.get(u["type"], u["type"])
        lines.append(f"  • {fmt_due(u['due'], now)} | {u['course']} | [{t}] {u['title']}")
    if not upcoming and not missing:
        lines.append("  없음 👍")
    return "\n".join(lines)


def write_json(upcoming, missing, lecs, lec_err, now):
    """앱(LMS 체커.app)이 읽는 구조화된 결과."""
    iso = lambda d: d.isoformat() if d else None
    data = {
        "checked_at": now.isoformat(),
        "lecture_error": lec_err,
        "lectures": [{"course": l["course"], "cid": l["cid"], "week": l["week"], "title": l["title"],
                      "due": iso(l["due"]), "late": l["late"],
                      "url": f"{BASE}/courses/{l['cid']}/external_tools/140"} for l in lecs],
        "missing": [{"course": m["course"], "title": m["title"], "due": iso(m["due"]), "url": m.get("url", "")}
                    for m in missing],
        "upcoming": [{"course": u["course"], "title": u["title"], "type": TYPE_KO.get(u["type"], u["type"]),
                      "due": iso(u["due"]), "url": u.get("url", "")} for u in upcoming],
    }
    tmp = JSON_OUT + ".tmp"
    with open(tmp, "w") as f:
        json.dump(data, f, ensure_ascii=False, indent=1)
    os.replace(tmp, JSON_OUT)


def open_details():
    """앱이 설치돼 있으면 앱으로, 아니면 텍스트 파일로."""
    if subprocess.run(["open", "-a", APP_NAME], capture_output=True).returncode != 0:
        subprocess.run(["open", "-e", OUT])


def popup(summary_title, body):
    script = ['on run argv',
              'set r to display dialog (item 2 of argv) with title (item 1 of argv) '
              'buttons {"자세히", "확인"} default button "확인" giving up after 900',
              'return button returned of r', 'end run']
    args = ["osascript"]
    for s in script:
        args += ["-e", s]
    r = subprocess.run(args + [summary_title, body], capture_output=True, text=True)
    if r.stdout.strip() == "자세히":
        open_details()


def main():
    os.makedirs(DIR, exist_ok=True)
    if "--login" in sys.argv:
        subprocess.run([VENV_PY, BROWSER, "--login"], stdout=subprocess.DEVNULL)
        print("로그인 세션 저장 완료. 이제 --force로 확인해봐.")
        return
    now = datetime.now(KST)
    today = now.date().isoformat()
    if not FORCE:
        if now.hour < 5:
            return
        if os.path.exists(STATE) and open(STATE).read().strip() == today:
            return

    tok = token()
    last_err = None
    for _ in range(6):  # 깨어난 직후 와이파이 연결 대기
        try:
            upcoming, missing = collect(tok, now)
            break
        except Exception as e:
            last_err = e
            time.sleep(10)
    else:
        print(f"LMS 접속 실패: {last_err}", file=sys.stderr)
        if NO_POPUP:
            sys.exit(1)
        return  # 성공 못 했으니 다음 주기에 재시도

    lecs, lec_err = [], None
    for attempt in range(3):  # 깨어난 직후 네트워크/브라우저 일시 오류 대비
        try:
            lecs, lec_err = lectures(tok, now), None
            break
        except Exception as e:  # 강의만 실패해도 나머지는 표시
            lec_err = str(e) or type(e).__name__
            print(f"{now:%F %T} 강의 조회 실패({attempt + 1}/3): {lec_err}", file=sys.stderr)
            if lec_err in FATAL:
                break
            time.sleep(30)
    if lec_err and lec_err not in FATAL and not FORCE:
        # 일시 오류면 오늘 완료 처리 안 하고 다음 주기(10분 뒤)에 재시도. 3번째 주기엔 오류라도 보여줌.
        fails = {}
        if os.path.exists(FAILS):
            try:
                fails = json.load(open(FAILS))
            except Exception:
                pass
        n = fails.get(today, 0) + 1
        json.dump({today: n}, open(FAILS, "w"))
        if n < 3:
            return
    if lec_err:
        lec_err = FATAL.get(lec_err) or TRANSIENT_MSG.get(lec_err) or lec_err[:150]

    text = render(upcoming, missing, lecs, lec_err, now)
    with open(OUT, "w") as f:
        f.write(text + "\n")
    write_json(upcoming, missing, lecs, lec_err, now)
    with open(STATE, "w") as f:
        f.write(today)
    if NO_POPUP:
        return

    soon = [u for u in upcoming if u["due"] and (u["due"].date() - now.date()).days <= 1]
    lec_tag = "강의 ?" if lec_err else f"강의 {len(lecs)}"
    title = f"LMS: {lec_tag} · 미제출 {len(missing)} · 오늘/내일 마감 {len(soon)} · 7일 내 {len(upcoming)}"
    body = text if len(text) < 1500 else text[:1500] + "\n…(자세히 눌러서 전체 보기)"
    popup(title, body)


if __name__ == "__main__":
    main()
