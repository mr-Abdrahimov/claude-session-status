// A macOS menu bar item for the session-status mod: every Claude Code chat's
// task, whether it is working, and where its changes stand on the way to
// GitHub. It reads the records the mod writes to ~/.claude/session-status.

import AppKit

struct GitStatus: Decodable {
    let repo: String?
    let branch: String
    let short: String
    let subject: String?
    let when: String?
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

    // SF Symbols of one shape and size, so the column reads at a glance.
    var symbol: String {
        switch self {
        case .uncommitted: return "pencil.circle.fill"
        case .committed: return "arrow.up.circle.fill"
        case .deploying: return "clock.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .succeeded: return "checkmark.circle.fill"
        case .none: return "minus.circle"
        }
    }

    var color: NSColor {
        switch self {
        case .uncommitted: return .systemPurple
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

func activitySymbol(_ record: SessionRecord, now: Double) -> String {
    if !isLive(record, now: now) { return "circle.dashed" }
    switch record.activity {
    case "working": return "circle.fill"
    case "waiting": return "circle.lefthalf.filled"
    default: return "circle"
    }
}

let titleFont = NSFont.systemFont(ofSize: 14, weight: .medium)
let rowFont = NSFont.menuFont(ofSize: 13)
let detailFont = NSFont.menuFont(ofSize: 12)
// Two status symbols, then the text: every line of a task starts here.
let textColumn: CGFloat = 50
// Long titles and commit subjects are cut so the menu stays narrow.
let titleLimit = 46
let detailLimit = 44

func cut(_ text: String, _ limit: Int) -> String {
    text.count > limit ? String(text.prefix(limit - 1)) + "…" : text
}

// A symbol drawn at the text's size in one color, sitting on the baseline.
func icon(_ name: String, _ color: NSColor, size: CGFloat = 12) -> NSAttributedString {
    let config = NSImage.SymbolConfiguration(pointSize: size, weight: .medium)
        // A filled badge draws its glyph in white over the color, so a pencil
        // and a check stay apart even at menu bar size.
        .applying(NSImage.SymbolConfiguration(
            paletteColors: name.hasSuffix(".circle.fill") ? [.white, color] : [color]))
    guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(config) else { return NSAttributedString(string: "•") }
    let attachment = NSTextAttachment()
    attachment.image = image
    attachment.bounds = CGRect(x: 0, y: -(size - 8) / 2, width: size + 2, height: size + 2)
    return NSAttributedString(attachment: attachment)
}

func plain(_ text: String, _ color: NSColor = .labelColor) -> NSAttributedString {
    NSAttributedString(string: text, attributes: [.font: rowFont, .foregroundColor: color])
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
        func add(_ symbol: String, _ count: Int?, _ color: NSColor) {
            if title.length > 0 { title.append(NSAttributedString(string: "  ", attributes: [.font: font])) }
            title.append(icon(symbol, color))
            if let count = count {
                title.append(NSAttributedString(string: " \(count)", attributes: [.font: font, .foregroundColor: NSColor.labelColor]))
            }
        }
        let live = records.filter { isLive($0, now: now) }
        let working = live.filter { $0.activity == "working" }.count
        let waiting = live.filter { $0.activity == "waiting" }.count
        if working > 0 { add("circle.fill", working, .systemOrange) }
        if waiting > 0 { add("circle.lefthalf.filled", waiting, .systemYellow) }
        for stageCase in [Stage.uncommitted, .committed, .deploying, .failed] {
            let count = live.filter { stage(of: $0.git) == stageCase }.count
            if count > 0 { add(stageCase.symbol, count, stageCase.color) }
        }
        if title.length == 0 {
            if live.isEmpty { add("circle.dashed", nil, .secondaryLabelColor) }
            else { add(Stage.succeeded.symbol, nil, .systemGreen) }
        }
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
            let gitStage = stage(of: record.git)
            let stageText = record.git == nil ? "" : " · \(gitStage.mark) \(gitStage.label)"
            lines.append("\(mark) \(cut(title, 60))")
            lines.append("    \(activity) · \(modelLine(record.model, record.effort))\(stageText)")
            for agent in record.agents where activeAgent.contains(agent.status) {
                lines.append("    ↳ \(cut(agent.label, 50)) — \(modelLine(agent.model, agent.effort))")
            }
        }
        return lines.joined(separator: "\n")
    }

    // Opens the real menu for a few seconds, then quits: a check without a mouse.
    func showMenu(for seconds: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
            let close = Timer(timeInterval: seconds, repeats: false) { [self] _ in
                item.menu?.cancelTracking()
                exit(0)
            }
            RunLoop.main.add(close, forMode: .common)
            item.button?.performClick(nil)
        }
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
            menu.addItem(projectItem(key, list, now: now))
            for record in list {
                menu.addItem(taskItem(record, now: now))
                for agent in record.agents where activeAgent.contains(agent.status) {
                    menu.addItem(agentItem(agent))
                }
            }
        }
        menu.addItem(.separator())
        menu.addItem(legendItem())
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Выйти", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func style() -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.tabStops = [NSTextTab(textAlignment: .left, location: textColumn)]
        style.headIndent = textColumn
        style.lineSpacing = 2
        return style
    }

    private func styled(_ text: NSMutableAttributedString) -> NSAttributedString {
        text.addAttribute(.paragraphStyle, value: style(), range: NSRange(location: 0, length: text.length))
        return text
    }

    // The project: its name, and the build of its last pushed commit with a
    // link to it.
    private func projectItem(_ key: String, _ list: [SessionRecord], now: Double) -> NSMenuItem {
        let name = key.split(separator: "/").last.map(String.init) ?? key
        let text = NSMutableAttributedString(string: name, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .bold), .foregroundColor: NSColor.labelColor])
        let git = list.filter { isLive($0, now: now) }.compactMap { $0.git }.first
        if let git = git, git.ci != "unknown" {
            let ciStage: Stage = git.ci == "success" ? .succeeded : git.ci == "failure" ? .failed
                : git.ci == "pending" ? .deploying : .none
            text.append(NSAttributedString(string: "   ", attributes: [.font: rowFont]))
            text.append(icon(ciStage.symbol, ciStage.color))
            let what = git.ciName.isEmpty ? "сборок нет" : git.ciName
            text.append(NSAttributedString(string: " \(cut(what, 30))", attributes: [
                .font: detailFont, .foregroundColor: NSColor.secondaryLabelColor]))
        }
        let menuItem = NSMenuItem(title: "", action: #selector(openURL(_:)), keyEquivalent: "")
        menuItem.attributedTitle = text
        menuItem.target = self
        menuItem.representedObject = git?.ciUrl
        menuItem.isEnabled = git?.ciUrl != nil
        menuItem.toolTip = git?.ciUrl == nil ? nil : "Открыть сборку на GitHub"
        return menuItem
    }

    // One chat as a block: two status symbols and the task, then what it is
    // doing and on which model, then where its last commit stands. A click
    // opens the chat in the Claude app.
    private func taskItem(_ record: SessionRecord, now: Double) -> NSMenuItem {
        let (_, activity, activityColor) = activityMark(record, now: now)
        let live = isLive(record, now: now)
        // A closed chat's git status is as old as its last write: not shown.
        let gitStage: Stage? = live && record.git != nil ? stage(of: record.git) : nil
        let title = record.title.isEmpty ? record.project : record.title
        let text = NSMutableAttributedString()
        text.append(icon(activitySymbol(record, now: now), activityColor, size: 15))
        text.append(NSAttributedString(string: " ", attributes: [.font: rowFont]))
        if let gitStage = gitStage {
            text.append(icon(gitStage.symbol, gitStage.color, size: 15))
        } else {
            text.append(icon("minus.circle", .quaternaryLabelColor, size: 15))
        }
        text.append(NSAttributedString(string: "\t" + cut(title, titleLimit), attributes: [
            .font: titleFont, .foregroundColor: live ? NSColor.labelColor : NSColor.secondaryLabelColor]))

        let active = record.agents.filter { activeAgent.contains($0.status) }.count
        var doing = "\(activity) \(ago(now - record.since / 1000)) · \(modelLine(record.model, record.effort))"
        if active > 0 { doing += " · агентов: \(active)" }
        text.append(NSAttributedString(string: "\u{2028}" + doing, attributes: [
            .font: detailFont, .foregroundColor: NSColor.secondaryLabelColor]))

        if let git = record.git, live {
            var commit = "\(git.branch) · \(git.short)"
            if let subject = git.subject, !subject.isEmpty { commit += " «\(cut(subject, detailLimit - commit.count))»" }
            if let when = git.when, !when.isEmpty { commit += " · \(when)" }
            var changes: [String] = []
            if let dirty = git.dirty, dirty > 0 { changes.append("изменено файлов: \(dirty)") }
            if git.ahead > 0 { changes.append("не запушено коммитов: \(git.ahead)") }
            text.append(NSAttributedString(string: "\u{2028}" + commit, attributes: [
                .font: detailFont, .foregroundColor: NSColor.secondaryLabelColor]))
            if !changes.isEmpty {
                text.append(NSAttributedString(string: "\u{2028}" + changes.joined(separator: " · "), attributes: [
                    .font: detailFont, .foregroundColor: Stage.uncommitted.color]))
            }
        }
        let menuItem = NSMenuItem(title: "", action: #selector(openChat(_:)), keyEquivalent: "")
        menuItem.attributedTitle = styled(text)
        menuItem.target = self
        menuItem.representedObject = record.appId
        menuItem.isEnabled = !(record.appId ?? "").isEmpty
        menuItem.toolTip = menuItem.isEnabled ? "Открыть чат в Claude" : nil
        return menuItem
    }

    private func agentItem(_ agent: AgentRow) -> NSMenuItem {
        let text = NSMutableAttributedString(string: "\t↳ " + cut(agent.label, 34), attributes: [
            .font: rowFont, .foregroundColor: NSColor.labelColor])
        text.append(NSAttributedString(string: "  " + modelLine(agent.model, agent.effort), attributes: [
            .font: detailFont, .foregroundColor: NSColor.secondaryLabelColor]))
        let menuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        menuItem.attributedTitle = styled(text)
        menuItem.isEnabled = false
        return menuItem
    }

    // What the symbols mean: the chat's activity, then its changes' stage.
    private func legendItem() -> NSMenuItem {
        let text = NSMutableAttributedString()
        func add(_ symbol: String, _ color: NSColor, _ label: String) {
            text.append(icon(symbol, color))
            text.append(NSAttributedString(string: " \(label)    ", attributes: [
                .font: detailFont, .foregroundColor: NSColor.secondaryLabelColor]))
        }
        add("circle.fill", .systemOrange, "работает")
        add("circle.lefthalf.filled", .systemYellow, "ждёт разрешения")
        add("circle", .secondaryLabelColor, "готов")
        add("circle.dashed", .tertiaryLabelColor, "закрыт")
        text.append(NSAttributedString(string: "\u{2028}", attributes: [.font: detailFont]))
        for stageCase in [Stage.uncommitted, .committed, .deploying, .failed, .succeeded] {
            add(stageCase.symbol, stageCase.color, stageCase.label)
        }
        let menuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 4
        text.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: text.length))
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
if CommandLine.arguments.contains("--show-menu") {
    controller.showMenu(for: 6)
}
app.run()
