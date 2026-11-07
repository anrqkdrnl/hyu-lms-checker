// LMS 체커.app — 한양대 LMS(Canvas)에서 미수강 강의·미제출 과제·7일 내 마감을 모아 보여줌.
// 앱 안 브라우저로 로그인해서 조회한다 (읽기 전용: 재생·출석·제출 등 상태를 바꾸는 동작 없음).
import AppKit
import SwiftUI
import Combine

let lmsBase = "https://learning.hanyang.ac.kr"
let lmsFiles = AppFiles("LMS 체커")
let lmsCreds = Credentials(idService: "hyu-lms-id", pwService: "hyu-lms-pw")
let lmsAgent = LaunchAgent(label: "io.github.anrqkdrnl.lmschecker.auto")
let lmsResultFile = "latest.json"

// MARK: - 결과 모델

struct LMSData: Codable {
    struct Lecture: Codable, Identifiable {
        let course: String, cid: String, week: String, title: String
        let due: String?
        let late: Bool
        let url: String
        var id: String { cid + "|" + week + "|" + title }
    }

    struct Item: Codable, Identifiable {
        let course: String, title: String
        let type: String?
        let due: String?
        let url: String?
        var id: String { course + "|" + title + "|" + (due ?? "") }
    }

    let checked_at: String
    let lecture_error: String?
    let lectures: [Lecture]
    let missing: [Item]
    let upcoming: [Item]

    var summary: String {
        let soon = upcoming.filter { DateUtil.parse($0.due).map { DateUtil.dayDiff($0) <= 1 } ?? false }.count
        let lec = lecture_error == nil ? "강의 \(lectures.count)" : "강의 ?"
        return "\(lec) · 미제출 \(missing.count) · 오늘/내일 마감 \(soon) · 7일 내 \(upcoming.count)"
    }
}

// MARK: - 조회 엔진

@MainActor
final class LMSEngine {
    static let videoTypes: Set<String> = ["mp4", "movie", "screenlecture"]
    static let typeKO = ["assignment": "과제", "quiz": "퀴즈", "discussion_topic": "토론",
                         "wiki_page": "페이지", "calendar_event": "일정", "planner_note": "메모"]

    var progress: (String) -> Void = { _ in }

    /// 로그인만 시험 (설정 마법사)
    func testLogin(_ uid: String, _ pw: String) async throws {
        let web = WebSession()
        defer { web.close() }
        try await login(web, uid, pw)
    }

    /// 결과 + 강의 오류가 일시적인지
    func run() async throws -> (LMSData, Bool) {
        guard let (uid, pw) = await lmsCreds.load() else { throw WebError.noCredentials }
        let web = WebSession()
        defer { web.close() }
        let now = Date()

        progress("LMS 로그인 중…")
        try await login(web, uid, pw)

        progress("과목·과제 목록 가져오는 중…")
        let courses = (try await api(web, "/api/v1/courses?enrollment_state=active&per_page=100") as? [[String: Any]]) ?? []
        var names: [String: String] = [:]
        for c in courses {
            if let id = c["id"] { names["\(id)"] = clean(c["name"] as? String ?? "") }
        }
        let upcoming = try await planner(web, now)
        let missing = (try? await missingSubmissions(web)) ?? []

        var lectures: [LMSData.Lecture] = []
        var lecErr: String?
        var lecTransient = false
        progress("강의(주차학습) 목록 가져오는 중…")
        do {
            lectures = try await self.lectures(web, Array(names.keys).sorted(), names)
        } catch {
            lecErr = error.message
            lecTransient = error.isTransient
            lmsFiles.log("강의 조회 실패: \(error.message)")
        }
        let data = LMSData(checked_at: DateUtil.iso(now)!, lecture_error: lecErr, lectures: lectures,
                           missing: missing, upcoming: upcoming)
        return (data, lecErr != nil && lecTransient)
    }

    // 로그인: LMS 첫 화면 → 로그인 폼이면 키체인 아이디/비번 입력
    private func login(_ web: WebSession, _ uid: String, _ pw: String) async throws {
        try await web.go(lmsBase + "/")
        var found: String?
        try await web.until(45, "LMS 로그인 페이지") {
            found = await web.first(["#global_nav_profile_link", "#uid"])
            return found != nil
        }
        if found == "#global_nav_profile_link" { return }
        try await web.submitHanyangLogin(uid, pw)
        try await web.until(60, "LMS 로그인", failOnAlert: true) { await web.exists("#global_nav_profile_link") }
    }

    /// 로그인된 페이지 안에서 Canvas API 호출 (세션 쿠키 사용 → 액세스 토큰 불필요)
    private func api(_ web: WebSession, _ path: String, bearer: String? = nil) async throws -> Any {
        let r = try await web.js("""
            const h = {Accept: 'application/json'};
            if (bearer) h['Authorization'] = 'Bearer ' + bearer;
            const r = await fetch(path, {headers: h, credentials: 'include'});
            return {status: r.status, text: await r.text()};
            """, ["path": path, "bearer": bearer ?? ""]) as? [String: Any]
        let status = (r?["status"] as? NSNumber)?.intValue ?? 0
        var text = r?["text"] as? String ?? ""
        guard status == 200 else { throw WebError.other("LMS API \(path.split(separator: "?")[0]) → HTTP \(status)") }
        if text.hasPrefix("while(1);") { text.removeFirst("while(1);".count) }
        return try JSONSerialization.jsonObject(with: Data(text.utf8))
    }

    private func clean(_ s: String) -> String {
        s.replacingOccurrences(of: #"^\d+HY\d+_"#, with: "", options: .regularExpression)
    }

    private func absURL(_ u: String?) -> String {
        guard let u, !u.isEmpty else { return "" }
        return u.hasPrefix("http") ? u : lmsBase + u
    }

    private func planner(_ web: WebSession, _ now: Date) async throws -> [LMSData.Item] {
        let start = DateUtil.ymd(now)
        let end = DateUtil.ymd(now.addingTimeInterval(7 * 86400))
        let items = (try await api(web, "/api/v1/planner/items?start_date=\(start)&end_date=\(end)&per_page=100") as? [[String: Any]]) ?? []
        var out: [LMSData.Item] = []
        for it in items {
            if ((it["planner_override"] as? [String: Any])?["marked_complete"] as? Bool) == true { continue }
            if let sub = it["submissions"] as? [String: Any],
               (sub["submitted"] as? Bool) == true || (sub["graded"] as? Bool) == true { continue }
            let p = it["plannable"] as? [String: Any] ?? [:]
            let type = it["plannable_type"] as? String ?? ""
            out.append(.init(course: clean(it["context_name"] as? String ?? ""),
                             title: (p["title"] as? String) ?? (p["name"] as? String) ?? "(제목 없음)",
                             type: Self.typeKO[type] ?? type,
                             due: DateUtil.iso(DateUtil.parse((it["plannable_date"] as? String) ?? (p["due_at"] as? String))),
                             url: absURL(it["html_url"] as? String)))
        }
        return out.sorted { (DateUtil.parse($0.due) ?? .distantFuture) < (DateUtil.parse($1.due) ?? .distantFuture) }
    }

    private func missingSubmissions(_ web: WebSession) async throws -> [LMSData.Item] {
        let arr = (try await api(web, "/api/v1/users/self/missing_submissions?include[]=course&per_page=100") as? [[String: Any]]) ?? []
        return arr.map { a in
            .init(course: clean((a["course"] as? [String: Any])?["name"] as? String ?? ""),
                  title: a["name"] as? String ?? "", type: nil,
                  due: DateUtil.iso(DateUtil.parse(a["due_at"] as? String)),
                  url: absURL(a["html_url"] as? String))
        }
    }

    /// 주차학습(LearningX): 페이지를 한 번 열어 xn_api_token(수명 2시간)을 받고 과목별 모듈 API 조회
    private func lectures(_ web: WebSession, _ cids: [String], _ names: [String: String]) async throws -> [LMSData.Lecture] {
        guard !cids.isEmpty else { return [] }
        var token: String?
        for cid in cids where token == nil {
            do { try await web.go("\(lmsBase)/courses/\(cid)/external_tools/140") } catch { continue }
            for _ in 0..<30 {
                if let t = await web.cookie("xn_api_token") { token = t; break }
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        guard let token else { throw WebError.timeout("주차학습 토큰(xn_api_token)") }

        var res: [LMSData.Lecture] = []
        for cid in cids {
            guard let mods = try? await api(web, "/learningx/api/v1/courses/\(cid)/modules", bearer: token) as? [[String: Any]]
            else { continue }  // LearningX 안 쓰는 과목
            for m in mods {
                for it in m["module_items"] as? [[String: Any]] ?? [] {
                    let cd = it["content_data"] as? [String: Any] ?? [:]
                    let kind = (cd["item_content_data"] as? [String: Any])?["content_type"] as? String ?? ""
                    guard it["content_type"] as? String == "attendance_item", Self.videoTypes.contains(kind) else { continue }
                    guard (cd["use_attendance"] as? Bool) == true, (it["completed"] as? Bool) != true else { continue }
                    let due: String?, late: Bool
                    switch cd["lecture_period_status"] as? String {
                    case "open": due = cd["due_at"] as? String; late = false
                    case "late": due = (cd["late_at"] as? String) ?? (cd["lock_at"] as? String); late = true
                    default: continue  // 예정 / 마감됨
                    }
                    res.append(.init(course: names[cid] ?? cid, cid: cid, week: m["title"] as? String ?? "",
                                     title: it["title"] as? String ?? "", due: DateUtil.iso(DateUtil.parse(due)), late: late,
                                     url: "\(lmsBase)/courses/\(cid)/external_tools/140"))
                }
            }
        }
        return res.sorted {
            let a = DateUtil.parse($0.due) ?? .distantFuture, b = DateUtil.parse($1.due) ?? .distantFuture
            return a != b ? a < b : $0.course < $1.course
        }
    }
}

// MARK: - 화면 상태

@MainActor
final class LMSStore: ObservableObject {
    @Published var data: LMSData?
    @Published var running: Date?
    @Published var runMessage = ""
    @Published var error: String?
    var openSettings: () -> Void = {}
    private var loadedAt: Date?

    func load() {
        data = lmsFiles.load(LMSData.self, lmsResultFile)
        loadedAt = lmsFiles.mtime(lmsResultFile)
    }

    /// 다른 프로세스(아침 자동 실행)가 결과를 갱신했으면 다시 읽기
    func reloadIfChanged() {
        if running == nil, let m = lmsFiles.mtime(lmsResultFile), m != loadedAt { load() }
    }

    func check() {
        guard running == nil else { return }
        running = Date()
        error = nil
        let engine = LMSEngine()
        engine.progress = { [weak self] in self?.runMessage = $0 }
        Task {
            defer { running = nil }
            do {
                let (d, _) = try await engine.run()
                try? lmsFiles.save(d, lmsResultFile)
                DailyGuard().markDone()
                load()
            } catch {
                self.error = error.message
                lmsFiles.log("지금 확인 실패: \(error.message)")
            }
        }
    }
}

// MARK: - 뷰

struct DueRow: View {
    let title: String
    let subtitle: String
    let due: Date?
    let urgentHours: Double
    var badge: String? = nil
    let url: String?

    var body: some View {
        let now = Date()
        let n = due.map(DateUtil.dayDiff)
        let urgent = due.map { $0.timeIntervalSince(now) < urgentHours * 3600 } ?? false
        let color: Color = urgent ? .red : (n ?? 99) <= 2 ? .orange : .secondary
        Button {
            openURL(url)
        } label: {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        if urgent { Text("🔥") }
                        Text(title).fontWeight(.medium).lineLimit(2)
                        if let badge {
                            Text(badge).font(.caption2.bold()).padding(.horizontal, 5).padding(.vertical, 1)
                                .background(.orange.opacity(0.2), in: Capsule())
                        }
                    }
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 3) {
                    Text(n.map(DateUtil.ddayTag) ?? "마감 없음").font(.callout.bold().monospacedDigit()).foregroundStyle(color)
                    if let due { Text(DateUtil.label(due)).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                }
            }
            .contentShape(Rectangle())
            .padding(.vertical, 3)
        }
        .buttonStyle(.plain)
        .help("클릭하면 브라우저에서 LMS가 열려")
    }
}

struct SectionHeader: View {
    let icon: String, title: String, count: Int
    var body: some View {
        HStack(spacing: 6) {
            Text(icon)
            Text(title).font(.headline)
            Text("\(count)").font(.callout.bold().monospacedDigit()).foregroundStyle(.secondary)
        }
    }
}

struct LMSContentView: View {
    @ObservedObject var store: LMSStore
    let timer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            header
            if let e = store.error { ErrorBanner(message: e) { store.error = nil } }
            Divider()
            if let d = store.data { list(d) } else { empty }
        }
        .frame(minWidth: 520, minHeight: 480)
        .onReceive(timer) { _ in store.reloadIfChanged() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            store.reloadIfChanged()
        }
    }

    var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("LMS 체커").font(.title2.bold())
                if store.running != nil {
                    Text(store.runMessage).font(.callout).foregroundStyle(.secondary)
                } else if let d = store.data, let t = DateUtil.parse(d.checked_at) {
                    Text("마지막 확인 \(DateUtil.label(t)) · \(DateUtil.relative(t))").font(.callout).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let s = store.running { RunningIndicator(since: s, message: "") }
            Button { store.check() } label: { Label("지금 확인", systemImage: "arrow.clockwise") }
                .disabled(store.running != nil)
            Button { store.openSettings() } label: { Image(systemName: "gearshape") }.help("설정 (⌘,)")
        }
        .padding()
    }

    var empty: some View {
        ContentUnavailableView {
            Label("아직 확인 결과가 없어", systemImage: "tray")
        } description: {
            Text("‘지금 확인’을 누르면 미수강 강의·미제출 과제·7일 내 마감을 가져와. (30초~1분)")
        } actions: {
            Button("지금 확인") { store.check() }.disabled(store.running != nil)
        }
    }

    func list(_ d: LMSData) -> some View {
        List {
            Section {
                if let e = d.lecture_error {
                    Label(e, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout)
                } else if d.lectures.isEmpty {
                    Text("다 들었음 👍").foregroundStyle(.secondary)
                }
                ForEach(d.lectures) { l in
                    DueRow(title: l.title, subtitle: "\(l.course) · \(l.week)", due: DateUtil.parse(l.due),
                           urgentHours: 24, badge: l.late ? "지각 인정" : nil, url: l.url)
                }
            } header: {
                SectionHeader(icon: "🎬", title: "미수강 강의", count: d.lectures.count)
            }

            if !d.missing.isEmpty {
                Section {
                    ForEach(d.missing) { m in
                        DueRow(title: m.title, subtitle: m.course, due: DateUtil.parse(m.due), urgentHours: 0, url: m.url)
                    }
                } header: {
                    SectionHeader(icon: "⚠️", title: "미제출 (마감 지남)", count: d.missing.count)
                }
            }

            Section {
                if d.upcoming.isEmpty { Text("없음 👍").foregroundStyle(.secondary) }
                ForEach(d.upcoming) { u in
                    DueRow(title: u.title, subtitle: [u.type, u.course].compactMap { $0 }.joined(separator: " · "),
                           due: DateUtil.parse(u.due), urgentHours: 24, url: u.url)
                }
            } header: {
                SectionHeader(icon: "📌", title: "7일 내 할 일", count: d.upcoming.count)
            }
        }
        .listStyle(.inset)
    }
}

struct LMSSettingsView: View {
    let rerunSetup: () -> Void

    var body: some View {
        Form {
            CredentialSection(title: "한양대 포털 계정", creds: lmsCreds)
            AutoRunSection(agent: lmsAgent, action: "결과 창을 띄워줘")
            Section {
                Button("오류 기록 보기") { NSWorkspace.shared.open(lmsFiles.url("error.log")) }
                Button("데이터 폴더 열기") { NSWorkspace.shared.open(lmsFiles.dir) }
                Button("처음 설정 다시 하기") { rerunSetup() }
            } header: { Text("기타") }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 520)
    }
}

// MARK: - 앱 수명주기

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = LMSStore()
    var mainWindow: NSWindow?
    var settingsWindow: NSWindow?
    var setupWindow: NSWindow?
    let args = CommandLine.arguments

    func applicationDidFinishLaunching(_ n: Notification) {
        Migration.defaults("lmschecker")
        Notifier.shared.setUp()
        Windows.installMenu(appName: "LMS 체커", target: self, settings: #selector(showSettings), refresh: #selector(refresh))
        store.openSettings = { [weak self] in self?.showSettings() }
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.async { self?.quitIfNoWindows() }
        }
        if args.contains("--selftest") { Task { await selfTest() }; return }
        if args.contains("--auto") {
            NSApp.setActivationPolicy(.accessory)
            Task { await runAuto() }
            return
        }
        Task {
            await Migration.agents("lmschecker", current: lmsAgent)
            await lmsAgent.refreshIfMoved()
            // 이미 허용/거부했으면 아무것도 안 뜸. 앱 ID가 바뀐 뒤 처음 열 때만 macOS가 다시 물어봄
            if UserDefaults.standard.bool(forKey: "setupDone") { Notifier.shared.requestPermission() }
            if UserDefaults.standard.bool(forKey: "setupDone") { showMain() } else { showSetup() }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { UserDefaults.standard.bool(forKey: "setupDone") ? showMain() : showSetup() }
        return true
    }

    private var visibleWindows: [NSWindow] {
        [mainWindow, settingsWindow, setupWindow].compactMap { $0 }.filter { $0.isVisible }
    }

    private func quitIfNoWindows() {
        if visibleWindows.isEmpty && !autoRunning { NSApp.terminate(nil) }
    }

    func showMain() {
        if mainWindow == nil {
            mainWindow = Windows.make("LMS 체커", size: NSSize(width: 620, height: 680), autosave: "main", LMSContentView(store: store))
        }
        store.load()
        Windows.present(mainWindow!)
    }

    @objc func showSettings() {
        if settingsWindow == nil {
            settingsWindow = Windows.make("설정", size: NSSize(width: 480, height: 520), resizable: false,
                                          LMSSettingsView(rerunSetup: { [weak self] in
                                              self?.settingsWindow?.close()
                                              self?.showSetup()
                                          }))
        }
        Windows.present(settingsWindow!)
    }

    @objc func refresh() {
        showMain()
        store.check()
    }

    func showSetup() {
        setupWindow?.close()
        let view = SetupView(
            appName: "LMS 체커", icon: "graduationcap.fill", tint: .blue,
            features: ["아직 안 들은 사이버강의와 출석 인정 마감", "마감이 지난 미제출 과제", "7일 안에 마감되는 과제·퀴즈·토론",
                       "정한 시각에 자동으로 확인해서 알려줌", "읽기 전용 — 강의 재생·출석·제출은 절대 건드리지 않음"],
            accountTitle: "LMS(learning.hanyang.ac.kr)에 로그인할 때 쓰는 한양대 포털 계정을 입력해줘.",
            creds: lmsCreds, agent: lmsAgent,
            autoAction: "결과 창을 띄워줘",
            testLogin: { try await LMSEngine().testLogin($0, $1) },
            onFinish: { [weak self] in
                guard let self else { return }
                self.showMain()
                self.setupWindow?.close()
                self.store.check()
            })
        setupWindow = Windows.make("LMS 체커 설정", size: NSSize(width: 520, height: 480), resizable: false, view)
        Windows.present(setupWindow!)
    }

    // launchd(--auto): 설정한 시각마다 1번, 결과 창(=예전 팝업) 띄우기
    var autoRunning = false

    func runAuto() async {
        let guardian = DailyGuard()
        guard UserDefaults.standard.bool(forKey: "setupDone"), guardian.shouldRun(), lmsFiles.lock() else {
            NSApp.terminate(nil); return
        }
        autoRunning = true
        defer { lmsFiles.unlock(); autoRunning = false }
        let engine = LMSEngine()
        var lastError: Error?
        for attempt in 0..<3 {  // 잠자기에서 막 깨어난 직후 네트워크 대기
            do {
                let (d, lecTransient) = try await engine.run()
                if lecTransient && guardian.recordFailure() < 3 {
                    lmsFiles.log("자동 실행: 강의 조회 일시 오류 → 10분 뒤 재시도")
                    return finishAuto(show: false)
                }
                try? lmsFiles.save(d, lmsResultFile)
                guardian.markDone()
                Notifier.shared.post("LMS 체커", d.summary)
                return finishAuto(show: true)
            } catch {
                lastError = error
                lmsFiles.log("자동 실행 실패(\(attempt + 1)/3): \(error.message)")
                if !error.isTransient { break }
                try? await Task.sleep(nanoseconds: 20_000_000_000)
            }
        }
        let e = lastError!
        if e.isTransient && guardian.recordFailure() < 3 { return finishAuto(show: false) }
        if e.isTransient { guardian.markDone() } else { guardian.stopForToday() }  // 로그인 거부는 반복하면 계정이 잠길 수 있어 오늘은 중단
        Notifier.shared.post("LMS 체커 오류", e.message)
        store.error = e.message
        finishAuto(show: true)
    }

    private func finishAuto(show: Bool) {
        if show && !otherInstanceRunning() {
            showMain()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { NSApp.terminate(nil) }
        }
    }

    // 개발용: --selftest → 조회 결과 요약을 출력하고 종료
    func selfTest() async {
        let t = Date()
        let engine = LMSEngine()
        engine.progress = { print("…", $0) }
        do {
            let (d, tr) = try await engine.run()
            print("OK \(Int(Date().timeIntervalSince(t)))s", d.summary, "lecErr=\(d.lecture_error ?? "nil") transient=\(tr)")
            for l in d.lectures.prefix(3) { print(" 강의", l.due ?? "-", l.course, l.title) }
            for u in d.upcoming.prefix(3) { print(" 할일", u.due ?? "-", u.type ?? "", u.title, u.url ?? "") }
            if args.contains("--save") { try? lmsFiles.save(d, lmsResultFile) }
        } catch {
            print("FAIL", error.message)
        }
        exit(0)
    }
}

@main
enum Main {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
