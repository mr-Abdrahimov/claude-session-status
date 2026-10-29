// A macOS menu bar item for the session-status mod: every Claude Code chat's
// task, whether it is working, and where its changes stand on the way to
// GitHub. It reads the records the mod writes to ~/.claude/session-status.

import AppKit

struct GitStatus: Decodable {
    let repo: String?
    let branch: String
    let short: String
    let ahead: Int
    let dirty: Int?
    let ci: String
    let ciName: String
    let ciUrl: String?
}

struct AgentRow: Decodable {
    let id: String
    let label: String
    let status: String
    let model: String?
    let effort: String?
}

struct SessionRecord: Decodable {
    let id: String
    let model: String
    let effort: String?
    let agents: [AgentRow]
    let appId: String?
    let title: String
    let cwd: String
    let project: String
    let activity: String
    let since: Double
    let updatedAt: Double
    let git: GitStatus?
}

// Where a task's changes stand, from the working tree to the deploy.
enum Stage: Int, CaseIterable {
    case failed, uncommitted, committed, deploying, succeeded, none

    var mark: String {
        switch self {
        case .uncommitted: return "✎"
        case .committed: return "⬆"
        case .deploying: return "◷"
        case .failed: return "✗"
        case .succeeded: return "✓"
        case .none: return ""
        }
    }

    var label: String {
        switch self {
        case .uncommitted: return "не закоммичено"
        case .committed: return "закоммичено"
        case .deploying: return "в процессе выкладки"
        case .failed: return "ошибка"
        case .succeeded: return "успешно"
        case .none: return "нет сборки"
        }
    }

    var color: NSColor {
        switch self {
        case .uncommitted: return .systemOrange
        case .committed: return .systemBlue
        case .deploying: return .systemYellow
        case .failed: return .systemRed
        case .succeeded: return .systemGreen
        case .none: return .secondaryLabelColor
        }
    }
}

let activeAgent: Set<String> = ["pending", "running", "waiting"]

// claude-opus-5-5 → Opus 5.5; an alias (opus, sonnet[1m]) → Opus, Sonnet 1M.
func prettyModel(_ id: String?) -> String {
    guard let id = id, !id.isEmpty else { return "?" }
    let lower = id.lowercased()
    guard let family = ["opus", "sonnet", "haiku", "fable"].first(where: { lower.contains($0) }) else { return id }
    var name = family.prefix(1).uppercased() + family.dropFirst()
    let pattern = "\(family)-(\\d{1,2})(?:-(\\d{1,2}))?(?!\\d)"
    if let regex = try? NSRegularExpression(pattern: pattern),
       let match = regex.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)) {
        let major = Range(match.range(at: 1), in: lower).map { String(lower[$0]) }
        let minor = Range(match.range(at: 2), in: lower).map { String(lower[$0]) }
        if let major = major { name += " " + major + (minor.map { "." + $0 } ?? "") }
    }
    if lower.contains("[1m]") { name += " 1M" }
    return name
}

func modelLine(_ model: String?, _ effort: String?) -> String {
    let level = (effort ?? "").isEmpty ? "" : " · \(effort!)"
    return prettyModel(model) + level
}

// A record that has not been written for this long belongs to a closed chat.
let staleSeconds = 45.0
// A closed chat stays listed this long.
let closedKeepSeconds = 3600.0

func stage(of git: GitStatus?) -> Stage {
    guard let git = git else { return .none }
    if (git.dirty ?? 0) > 0 { return .uncommitted }
    if git.ahead > 0 { return .committed }
    switch git.ci {
    case "pending": return .deploying
    case "failure": return .failed
    case "success": return .succeeded
    default: return .none
    }
}

func isLive(_ record: SessionRecord, now: Double) -> Bool {
    record.activity != "ended" && now - record.updatedAt / 1000 < staleSeconds
}

func activityMark(_ record: SessionRecord, now: Double) -> (String, String, NSColor) {
    if !isLive(record, now: now) { return ("◌", "закрыт", .tertiaryLabelColor) }
    switch record.activity {
    case "working": return ("●", "работает", .systemOrange)
    case "waiting": return ("◐", "ждёт разрешения", .systemYellow)
    default: return ("○", "готов", .secondaryLabelColor)
    }
}

func ago(_ seconds: Double) -> String {
    let s = max(0, Int(seconds))
    if s < 60 { return "\(s)с" }
    if s < 3600 { return "\(s / 60)м" }
    if s < 86400 { return "\(s / 3600)ч \(s % 3600 / 60)м" }
    return "\(s / 86400)д"
}

final class StatusController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let folder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/session-status")
    private var records: [SessionRecord] = []
    private var timer: Timer?

    override init() {
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        reload()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.reload()
        }
    }

    private func reload() {
        let now = Date().timeIntervalSince1970
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil)) ?? []
        records = files
            .filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder().decode(SessionRecord.self, from: Data(contentsOf: $0)) }
            .filter { isLive($0, now: now) || now - $0.updatedAt / 1000 < closedKeepSeconds }
            .sorted { $0.updatedAt > $1.updatedAt }
        drawTitle(now: now)
    }

    // The bar shows how many chats work now and how many tasks sit at each
    // stage short of a successful deploy; a lone check mark when all is done.
    private func drawTitle(now: Double) {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        let title = NSMutableAttributedString()
        func add(_ text: String, _ color: NSColor) {
            if title.length > 0 { title.append(NSAttributedString(string: "  ")) }
            title.append(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color]))
        }
        let live = records.filter { isLive($0, now: now) }
        let working = live.filter { $0.activity == "working" }.count
        let waiting = live.filter { $0.activity == "waiting" }.count
        if working > 0 { add("● \(working)", .systemOrange) }
        if waiting > 0 { add("◐ \(waiting)", .systemYellow) }
        for stageCase in [Stage.uncommitted, .committed, .deploying, .failed] {
            let count = live.filter { stage(of: $0.git) == stageCase }.count
            if count > 0 { add("\(stageCase.mark) \(count)", stageCase.color) }
        }
        if title.length == 0 { add(live.isEmpty ? "◌" : "✓", live.isEmpty ? .secondaryLabelColor : .systemGreen) }
        item.button?.attributedTitle = title
        item.button?.toolTip = tooltip(now: now)
    }

    // On hover: each live task with its model and level, and under it the
    // agents working on it, each with its own model and level.
    var hoverText: String { tooltip(now: Date().timeIntervalSince1970) }

    private func tooltip(now: Double) -> String {
        let live = records.filter { isLive($0, now: now) }
        if live.isEmpty { return "Нет открытых чатов Claude Code" }
        var lines: [String] = []
        for record in live {
            let (mark, activity, _) = activityMark(record, now: now)
            let title = record.title.isEmpty ? record.project : record.title
            let short = title.count > 60 ? String(title.prefix(59)) + "…" : title
            let gitStage = stage(of: record.git)
            let stageText = record.git == nil ? "" : " · \(gitStage.mark) \(gitStage.label)"
            lines.append("\(mark) \(short)")
            lines.append("    \(activity) · \(modelLine(record.model, record.effort))\(stageText)")
            for agent in record.agents where activeAgent.contains(agent.status) {
                let label = agent.label.count > 50 ? String(agent.label.prefix(49)) + "…" : agent.label
                lines.append("    ↳ \(label) — \(modelLine(agent.model, agent.effort))")
            }
        }
        return lines.joined(separator: "\n")
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        reload()
        menu.removeAllItems()
        let now = Date().timeIntervalSince1970
        if records.isEmpty {
            menu.addItem(disabled("Нет открытых чатов Claude Code с плагином session-status"))
        }
        var groups: [(String, [SessionRecord])] = []
        for record in records {
            let key = record.git?.repo ?? record.cwd
            if let index = groups.firstIndex(where: { $0.0 == key }) {
                groups[index].1.append(record)
            } else {
                groups.append((key, [record]))
            }
        }
        for (key, list) in groups {
            if menu.items.count > 0 { menu.addItem(.separator()) }
            let header = NSMenuItem()
            header.attributedTitle = NSAttributedString(
                string: key.split(separator: "/").last.map(String.init) ?? key,
                attributes: [.font: NSFont.boldSystemFont(ofSize: 13)])
            header.isEnabled = false
            menu.addItem(header)
            for record in list {
                menu.addItem(taskItem(record, now: now))
                for agent in record.agents where activeAgent.contains(agent.status) {
                    menu.addItem(agentItem(agent))
                }
            }
            if let git = list.compactMap({ $0.git }).first, let url = git.ciUrl {
                let open = NSMenuItem(title: "    Открыть сборку \(git.ciName)", action: #selector(openURL(_:)), keyEquivalent: "")
                open.target = self
                open.representedObject = url
                menu.addItem(open)
            }
        }
        menu.addItem(.separator())
        let legend = "✎ не закоммичено   ⬆ закоммичено   ◷ выкладка   ✗ ошибка   ✓ успешно"
        menu.addItem(disabled(legend))
        let quit = NSMenuItem(title: "Выйти", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    // One chat: its activity, its task, and the stage of its changes. A click
    // opens the chat in the Claude app.
    private func taskItem(_ record: SessionRecord, now: Double) -> NSMenuItem {
        let (mark, activity, activityColor) = activityMark(record, now: now)
        let gitStage = stage(of: record.git)
        let text = NSMutableAttributedString()
        let body = NSFont.menuFont(ofSize: 13)
        let small = NSFont.menuFont(ofSize: 11)
        text.append(NSAttributedString(string: "\(mark) ", attributes: [.font: body, .foregroundColor: activityColor]))
        let title = record.title.isEmpty ? record.project : record.title
        let short = title.count > 48 ? String(title.prefix(47)) + "…" : title
        text.append(NSAttributedString(string: short, attributes: [.font: body]))
        var detail = "   \(activity) \(ago(now - record.since / 1000)) · \(modelLine(record.model, record.effort))"
        if let git = record.git {
            detail += " · \(git.branch)"
            if let dirty = git.dirty, dirty > 0 { detail += " · файлов: \(dirty)" }
            if git.ahead > 0 { detail += " · коммитов: \(git.ahead)" }
        }
        text.append(NSAttributedString(string: detail, attributes: [.font: small, .foregroundColor: NSColor.secondaryLabelColor]))
        if gitStage != .none || record.git != nil {
            let stageText = "   \(gitStage.mark) \(gitStage.label)"
            text.append(NSAttributedString(string: stageText, attributes: [.font: small, .foregroundColor: gitStage.color]))
        }
        let menuItem = NSMenuItem(title: "", action: #selector(openChat(_:)), keyEquivalent: "")
        menuItem.attributedTitle = text
        menuItem.target = self
        menuItem.representedObject = record.appId
        menuItem.isEnabled = !(record.appId ?? "").isEmpty
        return menuItem
    }

    private func agentItem(_ agent: AgentRow) -> NSMenuItem {
        let label = agent.label.count > 50 ? String(agent.label.prefix(49)) + "…" : agent.label
        let text = NSMutableAttributedString(
            string: "      ↳ \(label)  ",
            attributes: [.font: NSFont.menuFont(ofSize: 12), .foregroundColor: NSColor.labelColor])
        text.append(NSAttributedString(
            string: modelLine(agent.model, agent.effort),
            attributes: [.font: NSFont.menuFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]))
        let menuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        menuItem.attributedTitle = text
        menuItem.isEnabled = false
        return menuItem
    }

    private func disabled(_ text: String) -> NSMenuItem {
        let menuItem = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        menuItem.isEnabled = false
        return menuItem
    }

    @objc private func openChat(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, !id.isEmpty,
              let url = URL(string: "claude://claude.ai/epitaxy/\(id)") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func openURL(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String, let url = URL(string: text) else { return }
        NSWorkspace.shared.open(url)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = StatusController()
// `--print` writes the hover text and exits: a check without a mouse.
if CommandLine.arguments.contains("--print") {
    print(controller.hoverText)
    exit(0)
}
app.run()
