// LMS 체커.app — ~/.lms_check/lms_check.py 의 GUI.
// 결과는 ~/.lms_check/latest.json (아침 자동 실행 / '지금 확인' 둘 다 여기에 씀)
import AppKit
import SwiftUI

let lmsDir = NSHomeDirectory() + "/.lms_check"
let lmsJSON = lmsDir + "/latest.json"
let lmsScript = lmsDir + "/lms_check.py"
let lmsAgent = LaunchAgent(label: "com.seongsu.lmscheck")

struct LMSData: Decodable {
    struct Lecture: Decodable, Identifiable {
        let course: String, cid: String, week: String, title: String
        let due: String?
        let late: Bool
        let url: String
        var id: String { cid + "|" + week + "|" + title }
    }

    struct Item: Decodable, Identifiable {
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
}

@MainActor
final class LMSStore: ObservableObject {
    @Published var data: LMSData?
    @Published var running: Date?
    @Published var runMessage = ""
    @Published var error: String?

    var python: String {
        // launchd가 쓰는 것과 같은 파이썬
        if let p = lmsAgent.programArguments().first, FileManager.default.isExecutableFile(atPath: p) { return p }
        for p in ["/Library/Frameworks/Python.framework/Versions/Current/bin/python3", "/usr/bin/python3"]
        where FileManager.default.isExecutableFile(atPath: p) { return p }
        return "/usr/bin/python3"
    }

    func load() {
        guard let d = FileManager.default.contents(atPath: lmsJSON) else { return }
        do { data = try JSONDecoder().decode(LMSData.self, from: d) } catch { self.error = "결과 파일 읽기 실패: \(error)" }
    }

    func check() {
        guard running == nil else { return }
        runMessage = "LMS 확인 중… (강의 목록은 브라우저로 가져와서 1~2분 걸려)"
        running = Date()
        error = nil
        Task {
            let r = await Shell.run(python, [lmsScript, "--force", "--no-popup"])
            running = nil
            if r.code != 0 { error = "확인 실패 (exit \(r.code))\n" + tail(r.err) }
            load()
        }
    }

    func manualLogin() {
        guard running == nil else { return }
        runMessage = "열린 크롬 창에서 직접 로그인해줘 (최대 5분)…"
        running = Date()
        error = nil
        Task {
            let r = await Shell.run(python, [lmsScript, "--login"])
            running = nil
            if r.code != 0 { error = "로그인 실패\n" + tail(r.err) }
            else { check() }
        }
    }
}

// MARK: - 뷰

struct DueRow: View {
    let title: String
    let subtitle: String
    let due: Date?
    let urgentHours: Double  // 이 시간 안이면 빨간색
    var badge: String? = nil
    let url: String?

    var body: some View {
        let now = Date()
        let n = due.map(DateUtil.dayDiff)
        let urgent = due.map { $0.timeIntervalSince(now) < urgentHours * 3600 } ?? false
        let color: Color = urgent ? .red : (n ?? 99) <= 2 ? .orange : .secondary
        Button {
            if let url { openURL(url) }
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
        .help(url.map { _ in "클릭하면 LMS에서 열려" } ?? "")
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
    @EnvironmentObject var store: LMSStore

    var body: some View {
        VStack(spacing: 0) {
            header
            if let e = store.error { ErrorBanner(message: e) { store.error = nil } }
            Divider()
            if let d = store.data { list(d) } else { empty }
        }
        .frame(minWidth: 520, minHeight: 480)
        .onAppear { store.load() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if store.running == nil { store.load() }  // 아침 자동 실행 결과 반영
        }
    }

    var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("LMS 체커").font(.title2.bold())
                if let d = store.data, let t = DateUtil.parse(d.checked_at) {
                    Text("마지막 확인 \(DateUtil.label(t)) · \(DateUtil.relative(t))").font(.callout).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let s = store.running { RunningIndicator(since: s, message: "") }
            Button { store.check() } label: { Label("지금 확인", systemImage: "arrow.clockwise") }
                .keyboardShortcut("r")
                .disabled(store.running != nil)
            SettingsLink { Image(systemName: "gearshape") }.help("설정")
        }
        .padding()
        .overlay(alignment: .bottomLeading) {
            if store.running != nil {
                Text(store.runMessage).font(.caption).foregroundStyle(.secondary).padding(.leading).padding(.bottom, 2)
            }
        }
    }

    var empty: some View {
        ContentUnavailableView {
            Label("아직 확인 결과가 없어", systemImage: "tray")
        } description: {
            Text("‘지금 확인’을 누르면 미수강 강의·미제출 과제·7일 내 마감을 가져와.")
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
    @EnvironmentObject var store: LMSStore
    @State private var canvasToken = ""
    @State private var tokenMsg = ""

    var body: some View {
        Form {
            CredentialSection(title: "한양 포털 계정 — 강의 목록 자동 로그인용", idService: "hyu-lms-id", pwService: "hyu-lms-pw")

            Section {
                SecureField("Canvas 액세스 토큰", text: $canvasToken, prompt: Text("새 토큰을 발급받았을 때만 입력"))
                HStack {
                    Button("저장") {
                        Task {
                            tokenMsg = await Keychain.write("hyu-lms", canvasToken) ? "저장했어 ✓" : "저장 실패"
                            canvasToken = ""
                        }
                    }.disabled(canvasToken.isEmpty)
                    Text(tokenMsg).font(.callout).foregroundStyle(.secondary)
                }
            } header: { Text("Canvas API 토큰 (과제·마감 조회용)") }

            Section {
                Button("브라우저 창 띄워서 직접 로그인") { store.manualLogin() }
                    .disabled(store.running != nil)
                Text("자동 로그인이 계속 실패할 때만 써. 로그인하면 세션이 저장돼.").font(.caption).foregroundStyle(.secondary)
            } header: { Text("로그인 문제 해결") }

            AutoRunSection(agent: lmsAgent, description: "매일 05시 이후 맥을 처음 깨울 때 1번 확인하고 팝업으로 알려줘")

            Section {
                Button("오류 로그 열기") { openFile(lmsDir + "/error.log", textEdit: true) }
                Button("데이터 폴더 열기") { openFile(lmsDir) }
            } header: { Text("기타") }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 560)
    }
}

@main
struct LMSCheckerApp: App {
    @NSApplicationDelegateAdaptor(QuitOnCloseDelegate.self) var delegate
    @StateObject private var store = LMSStore()

    var body: some Scene {
        Window("LMS 체커", id: "main") {
            LMSContentView().environmentObject(store)
        }
        .defaultSize(width: 620, height: 640)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
        Settings {
            LMSSettingsView().environmentObject(store)
        }
    }
}
