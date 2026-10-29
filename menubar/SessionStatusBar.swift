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

let rowFont = NSFont.menuFont(ofSize: 13)
let activityColumn: CGFloat = 22
let taskColumn: CGFloat = 158
let detailColumn: CGFloat = 470

// A symbol drawn at the text's size in one color, sitting on the baseline.
func icon(_ name: String, _ color: NSColor) -> NSAttributedString {
    let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        // A filled badge draws its glyph in white over the color, so a pencil
        // and a check stay apart even at menu bar size.
        .applying(NSImage.SymbolConfiguration(
            paletteColors: name.hasSuffix(".circle.fill") ? [.white, color] : [color]))
    guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(config) else { return NSAttributedString(string: "•") }
    let attachment = NSTextAttachment()
    attachment.image = image
    attachment.bounds = CGRect(x: 0, y: -2, width: 14, height: 14)
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

    func snapshot(to path: String) {
        let menu = NSMenu()
        menuNeedsUpdate(menu)
        let rowHeight: CGFloat = 22, width: CGFloat = 1000
        let size = NSSize(width: width, height: rowHeight * CGFloat(menu.items.count) + 12)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.windowBackgroundColor.setFill()
        NSRect(origin: .zero, size: size).fill()
        for (index, menuItem) in menu.items.enumerated() {
            let y = size.height - 6 - rowHeight * CGFloat(index + 1)
            if menuItem.isSeparatorItem {
                NSColor.separatorColor.setFill()
                NSRect(x: 14, y: y + rowHeight / 2, width: width - 28, height: 1).fill()
            } else {
                let text = menuItem.attributedTitle ?? NSAttributedString(string: menuItem.title, attributes: [.font: rowFont])
                text.draw(in: NSRect(x: 14, y: y + 3, width: width - 28, height: rowHeight))
            }
        }
        image.unlockFocus()
        if let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
           let png = bitmap.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
        }
    }

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
                let open = NSMenuItem(title: "", action: #selector(openURL(_:)), keyEquivalent: "")
                open.attributedTitle = row(
                    [plain("\t\tОткрыть сборку \(git.ciName)", .linkColor)], color: .linkColor)
                open.target = self
                open.representedObject = url
                menu.addItem(open)
            }
        }
        menu.addItem(.separator())
        let legend = NSMutableAttributedString()
        for stageCase in [Stage.uncommitted, .committed, .deploying, .failed, .succeeded] {
            legend.append(icon(stageCase.symbol, stageCase.color))
            legend.append(plain(" \(stageCase.label)   ", .secondaryLabelColor))
        }
        let legendItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        legendItem.attributedTitle = legend
        legendItem.isEnabled = false
        menu.addItem(legendItem)
        let quit = NSMenuItem(title: "Выйти", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    // Every row is laid out in the same columns: activity, the stage of the
    // changes, the task, then the details, so the statuses line up on the left.
    private func row(_ parts: [NSAttributedString], color: NSColor) -> NSMutableAttributedString {
        let style = NSMutableParagraphStyle()
        style.tabStops = [
            NSTextTab(textAlignment: .left, location: activityColumn),
            NSTextTab(textAlignment: .left, location: taskColumn),
            NSTextTab(textAlignment: .left, location: detailColumn),
        ]
        let text = NSMutableAttributedString()
        for part in parts { text.append(part) }
        text.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: text.length))
        return text
    }

    // One chat: its activity, the stage of its changes, its task. A click
    // opens the chat in the Claude app.
    private func taskItem(_ record: SessionRecord, now: Double) -> NSMenuItem {
        let (_, activity, activityColor) = activityMark(record, now: now)
        let live = isLive(record, now: now)
        // A closed chat's git status is as old as its last write: not shown.
        let gitStage: Stage? = live && record.git != nil ? stage(of: record.git) : nil
        let title = record.title.isEmpty ? record.project : record.title
        let short = title.count > 42 ? String(title.prefix(41)) + "…" : title
        var detail = "\(activity) \(ago(now - record.since / 1000)) · \(modelLine(record.model, record.effort))"
        if let git = record.git, live {
            detail += " · \(git.branch)"
            if let dirty = git.dirty, dirty > 0 { detail += " · файлов: \(dirty)" }
            if git.ahead > 0 { detail += " · коммитов: \(git.ahead)" }
        }
        var parts = [icon(activitySymbol(record, now: now), activityColor), plain("\t")]
        if let gitStage = gitStage {
            parts += [icon(gitStage.symbol, gitStage.color), plain(" \(gitStage.label)", gitStage.color)]
        } else {
            parts += [icon("minus", .tertiaryLabelColor)]
        }
        parts += [
            plain("\t" + short, live ? .labelColor : .secondaryLabelColor),
            plain("\t" + detail, .secondaryLabelColor),
        ]
        let menuItem = NSMenuItem(title: "", action: #selector(openChat(_:)), keyEquivalent: "")
        menuItem.attributedTitle = row(parts, color: .labelColor)
        menuItem.target = self
        menuItem.representedObject = record.appId
        menuItem.isEnabled = !(record.appId ?? "").isEmpty
        return menuItem
    }

    private func agentItem(_ agent: AgentRow) -> NSMenuItem {
        let label = agent.label.count > 40 ? String(agent.label.prefix(39)) + "…" : agent.label
        let menuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        menuItem.attributedTitle = row([
            plain("\t\t↳ " + label, .secondaryLabelColor),
            plain("\t" + modelLine(agent.model, agent.effort), .secondaryLabelColor),
        ], color: .secondaryLabelColor)
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
// `--snapshot <file.png>` draws the menu's rows to a picture and exits.
if let flag = CommandLine.arguments.firstIndex(of: "--snapshot"), flag + 1 < CommandLine.arguments.count {
    controller.snapshot(to: CommandLine.arguments[flag + 1])
    exit(0)
}
app.run()
