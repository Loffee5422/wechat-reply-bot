import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import ImageIO

struct Node: Codable {
    var role: String = ""
    var id: String = ""
    var title: String = ""
    var value: String = ""
    var description: String = ""
    var x: Double? = nil
    var y: Double? = nil
    var width: Double? = nil
    var height: Double? = nil
    var side: String? = nil
    var confidence: String? = nil
    var evidence: String? = nil
    var kind: String? = nil
    var mention: Bool? = nil
    var children: [Node] = []
}

struct Result: Codable {
    var ok: Bool
    var error: String? = nil
    var trusted: Bool
    var windowCount: Int = 0
    var tree: Node? = nil
    var chat: String? = nil
    var messages: [HistoryMessage]? = nil
    var kind: String? = nil
    var mention: Bool? = nil
    var historyPartial: Bool? = nil
    var restored: Bool? = nil
    var screenRecording: Bool? = nil
    var wechatRunning: Bool? = nil
    var executablePath: String? = nil
}

struct HistoryMessage: Codable {
    var text: String
    var side: String
    var confidence: String
    var evidence: String
    var x: Double?
    var y: Double?
}

var wechatPID: pid_t = 0

func str(_ e: AXUIElement, _ key: CFString) -> String {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(e, key, &v) == .success else { return "" }
    return (v as? String) ?? ""
}

func frame(_ e: AXUIElement) -> (Double, Double, Double, Double)? {
    var p: CFTypeRef?
    var s: CFTypeRef?
    guard AXUIElementCopyAttributeValue(e, kAXPositionAttribute as CFString, &p) == .success,
          AXUIElementCopyAttributeValue(e, kAXSizeAttribute as CFString, &s) == .success else { return nil }
    var point = CGPoint.zero
    var size = CGSize.zero
    guard AXValueGetValue(p as! AXValue, .cgPoint, &point), AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
    return (point.x, point.y, size.width, size.height)
}

func wechatWindowImage() -> (CGImage, CGRect)? {
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return nil }
    let candidates = raw.compactMap { info -> (CGWindowID, CGRect, Int)? in
        guard let pid = info[kCGWindowOwnerPID as String] as? Int, pid == Int(wechatPID),
              let bounds = info[kCGWindowBounds as String] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: bounds) else { return nil }
        let number = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? 0
        return (number, rect, Int(rect.width * rect.height))
    }.filter { $0.0 != 0 }.sorted { $0.2 > $1.2 }
    guard let (windowID, bounds, _) = candidates.first else { return nil }
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("wechat-ax-\(UUID().uuidString).png")
    let capture = Process()
    capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    capture.arguments = ["-l", String(windowID), "-o", "-x", path.path]
    guard (try? capture.run()) != nil else { return nil }
    let deadline = Date().addingTimeInterval(2)
    while capture.isRunning && Date() < deadline { usleep(20_000) }
    guard !capture.isRunning, capture.terminationStatus == 0,
          let png = try? Data(contentsOf: path),
          let source = CGImageSourceCreateWithData(png as CFData, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        try? FileManager.default.removeItem(at: path)
        return nil
    }
    try? FileManager.default.removeItem(at: path)
    return (image, bounds)
}

func colorCounts(_ image: CGImage, bounds: CGRect, f: (UInt8, UInt8, UInt8) -> Bool, row: CGRect) -> (Int, Int) {
    guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data), CFDataGetLength(data) > 0 else { return (0, 0) }
    let dataLength = CFDataGetLength(data)
    let channels = max(1, image.bitsPerPixel / 8)
    let scaleX = CGFloat(image.width) / max(1, bounds.width)
    let scaleY = CGFloat(image.height) / max(1, bounds.height)
    let y0 = max(0, Int(floor((row.minY - bounds.minY) * scaleY)))
    let y1 = min(image.height, Int(ceil((row.maxY - bounds.minY) * scaleY)))
    let x0 = max(0, Int(floor((row.minX - bounds.minX) * scaleX)))
    let x1 = min(image.width, Int(ceil((row.maxX - bounds.minX) * scaleX)))
    let mid = (x0 + x1) / 2
    var left = 0
    var right = 0
    guard x1 > x0, y1 > y0 else { return (0, 0) }
    for y in stride(from: y0, to: y1, by: 3) {
        for x in stride(from: x0, to: x1, by: 3) {
            let offset = y * image.bytesPerRow + x * channels
            guard offset >= 0 && offset + 2 < dataLength else { continue }
            let pixel = (bytes[offset], bytes[offset + 1], bytes[offset + 2])
            if f(pixel.0, pixel.1, pixel.2) {
                if x < mid { left += 1 } else { right += 1 }
            }
        }
    }
    return (left, right)
}

func colorEvidence(_ imageAndBounds: (CGImage, CGRect)?, row: Node) -> (Int, Int, Int, Int) {
    guard let (image, bounds) = imageAndBounds,
          let x = row.x, let y = row.y, let width = row.width, let height = row.height else { return (0, 0, 0, 0) }
    let rect = CGRect(x: x, y: y, width: width, height: height)
    let greenTest: (UInt8, UInt8, UInt8) -> Bool = { r, g, b in
        let ri = Int(r); let gi = Int(g); let bi = Int(b)
        return (gi > 145 && gi > ri + 22 && gi > bi + 12 && ri > 60) || (gi > 105 && gi > ri + 28 && gi > bi + 12)
    }
    let grayTest: (UInt8, UInt8, UInt8) -> Bool = { r, g, b in
        let maxc = Int(max(r, max(g, b))); let minc = Int(min(r, min(g, b)))
        return maxc - minc <= 8 && ((minc >= 38 && maxc <= 100) || (minc >= 205 && maxc <= 249))
    }
    let green = colorCounts(image, bounds: bounds, f: greenTest, row: rect)
    let gray = colorCounts(image, bounds: bounds, f: grayTest, row: rect)
    return (green.0, green.1, gray.0, gray.1)
}

func tree(_ e: AXUIElement, depth: Int = 0) -> Node {
    var n = Node(role: str(e, kAXRoleAttribute as CFString), id: str(e, "AXIdentifier" as CFString), title: str(e, kAXTitleAttribute as CFString), value: str(e, kAXValueAttribute as CFString), description: str(e, kAXDescriptionAttribute as CFString))
    if let f = frame(e) { n.x = f.0; n.y = f.1; n.width = f.2; n.height = f.3 }
    guard depth < 20 else { return n }
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &v) == .success, let children = v as? [AXUIElement] else { return n }
    n.children = children.map { tree($0, depth: depth + 1) }
    return n
}

func app() -> AXUIElement? {
    guard let running = NSWorkspace.shared.runningApplications.first(where: {
        ($0.localizedName == "微信" || $0.localizedName == "WeChat") && $0.activationPolicy == .regular
    }) else { return nil }
    wechatPID = running.processIdentifier
    return AXUIElementCreateApplication(running.processIdentifier)
}

func windows(_ a: AXUIElement) -> [AXUIElement] {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(a, kAXWindowsAttribute as CFString, &v) == .success else { return [] }
    return (v as? [AXUIElement]) ?? []
}

func json(_ value: Result) {
    let enc = JSONEncoder()
    enc.outputFormatting = [.sortedKeys]
    if let data = try? enc.encode(value) { print(String(data: data, encoding: .utf8)!) }
}

let trusted = AXIsProcessTrusted()
let command = CommandLine.arguments.dropFirst().first ?? "snapshot"
if command == "status" {
    let application = app()
    let running = application != nil
    let count = application.map { windows($0).count } ?? 0
    let ok = trusted && running && count > 0
    json(Result(ok: ok, error: ok ? nil : (trusted ? "wechat_window_unavailable" : "accessibility_permission_required"), trusted: trusted, windowCount: count, screenRecording: CGPreflightScreenCaptureAccess(), wechatRunning: running, executablePath: CommandLine.arguments[0]))
    exit(ok ? 0 : 1)
}
if command == "self-check" {
    let person = Node(id: "current_chat_name_label", value: "Alice")
    let heading = Node(id: "big_title_line_h_view", value: "Alice")
    let group = Node(id: "big_title_line_h_view", value: "Room(56)")
    let groupLabel = Node(id: "current_chat_name_label", value: "Room")
    assert(chatKind(Node(children: [heading, person]), chat: "Alice") == "person")
    assert(chatKind(Node(children: [group, groupLabel]), chat: "Room") == "group")
    print("self-check: ok")
    exit(0)
}
guard let application = app(), let window = windows(application).first else {
    json(Result(ok: false, error: trusted ? "wechat_window_unavailable" : "accessibility_permission_required", trusted: trusted))
    exit(1)
}

if command == "snapshot" {
    var current = tree(window)
    annotateSessionMetadata(&current)
    applyMessageGeometry(&current)
    json(Result(ok: true, trusted: trusted, windowCount: 1, tree: current))
    exit(0)
}

if command == "history" {
    guard CommandLine.arguments.count > 2 else {
        json(Result(ok: false, error: "usage_history_chat_limit", trusted: trusted)); exit(2)
    }
    let requestedChat = CommandLine.arguments[2]
    let limit = min(50, max(1, Int(CommandLine.arguments.dropFirst(3).first ?? "20") ?? 20))
    let before = tree(window)
    let previousChat = currentChat(before)
    if let input = find(before, id: "chat_input_field"), !input.value.isEmpty {
        json(Result(ok: false, error: "draft_or_input_busy", trusted: trusted)); exit(1)
    }
    var opened = false
    if previousChat != requestedChat {
        guard openSession(before, chat: requestedChat) else {
            json(Result(ok: false, error: "chat_not_visible_or_open_failed", trusted: trusted)); exit(1)
        }
        opened = true
    }
    var current = tree(window)
    let kind = chatKind(current, chat: requestedChat)
    let mention = find(current, id: "session_item_\(requestedChat)")?.title.contains("[有人@我]") ?? false
    applyMessageGeometry(&current)
    let listing = find(current, id: "chat_message_list")
    let messages = descendants(listing ?? Node()).compactMap { node -> HistoryMessage? in
        guard node.id == "chat_bubble_item_view" else { return nil }
        let text = node.value.isEmpty ? node.title : node.value
        guard !text.isEmpty else { return nil }
        let side = node.side ?? "unknown"
        return HistoryMessage(text: text, side: side, confidence: side == "unknown" ? "none" : "high", evidence: node.evidence ?? "unknown", x: node.x, y: node.y)
    }.suffix(limit)
    var restored = true
    if opened {
        let restoreRoot = tree(window)
        restored = openSession(restoreRoot, chat: previousChat)
    }
    json(Result(ok: true, trusted: trusted, windowCount: 1, chat: requestedChat, messages: Array(messages), kind: kind, mention: mention, historyPartial: true, restored: restored))
    exit(0)
}

func descendants(_ n: Node) -> [Node] { n.children + n.children.flatMap(descendants) }
func find(_ n: Node, id: String) -> Node? { if n.id == id { return n }; for c in n.children { if let hit = find(c, id: id) { return hit } }; return nil }

func locate(_ e: AXUIElement, id: String) -> AXUIElement? {
    if str(e, "AXIdentifier" as CFString) == id { return e }
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &v) == .success,
          let children = v as? [AXUIElement] else { return nil }
    for child in children {
        if let hit = locate(child, id: id) { return hit }
    }
    return nil
}

func postKey(_ keyCode: CGKeyCode, down: Bool) {
    let source = CGEventSource(stateID: .hidSystemState)
    CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down)?.postToPid(wechatPID)
}

func tapKey(_ keyCode: CGKeyCode) {
    postKey(keyCode, down: true)
    postKey(keyCode, down: false)
}

func currentChat(_ root: Node) -> String {
    guard let label = find(root, id: "current_chat_name_label") else { return "" }
    return label.value.isEmpty ? label.title : label.value
}

func chatKind(_ root: Node, chat: String) -> String {
    guard let title = find(root, id: "big_title_line_h_view"),
          let label = find(root, id: "current_chat_name_label") else { return "unknown" }
    let name = label.value.isEmpty ? label.title : label.value
    let heading = title.value.isEmpty ? title.title : title.value
    guard name == chat, heading.hasPrefix(name) else { return "unknown" }
    let suffix = String(heading.dropFirst(name.count)).trimmingCharacters(in: .whitespacesAndNewlines)
    if suffix.isEmpty { return "person" }
    let pairs = [("(", ")"), ("（", "）")]
    for (open, close) in pairs where suffix.hasPrefix(open) && suffix.hasSuffix(close) {
        let digits = suffix.dropFirst().dropLast()
        if !digits.isEmpty && digits.allSatisfy({ $0.isNumber }) { return "group" }
    }
    return "unknown"
}

func annotateSessionMetadata(_ root: inout Node) {
    let chat = currentChat(root)
    let kind = chatKind(root, chat: chat)
    func visit(_ node: inout Node) {
        for index in node.children.indices { visit(&node.children[index]) }
        guard node.id == "session_item_\(chat)" else { return }
        node.kind = kind
        node.mention = node.title.contains("[有人@我]")
    }
    visit(&root)
}

func sessionRows(_ root: Node) -> [Node] {
    descendants(root).filter { $0.id.hasPrefix("session_item_") }
        .sorted { ($0.y ?? .greatestFiniteMagnitude) < ($1.y ?? .greatestFiniteMagnitude) }
}

func openSession(_ root: Node, chat: String) -> Bool {
    let rows = sessionRows(root)
    guard let index = rows.firstIndex(where: { $0.id == "session_item_\(chat)" }),
          let listElement = locate(window, id: "session_list") else { return false }
    _ = AXUIElementSetAttributeValue(listElement, kAXFocusedAttribute as CFString, true as CFBoolean)
    if let rowElement = locate(window, id: "session_item_\(chat)") {
        _ = AXUIElementSetAttributeValue(rowElement, kAXFocusedAttribute as CFString, true as CFBoolean)
    }
    tapKey(115) // Home
    usleep(50_000)
    if index > 0 {
        for _ in 0..<index { tapKey(125); usleep(15_000) } // Down
    }
    tapKey(49) // Space selects a static-text session row; Return opens a second window.
    usleep(180_000)
    let after = tree(window)
    return currentChat(after) == chat
}

func applyMessageGeometry(_ root: inout Node) {
    guard CGPreflightScreenCaptureAccess(), let listing = find(root, id: "chat_message_list"), let image = wechatWindowImage() else { return }
    let leftX = listing.x ?? 0
    let listWidth = listing.width ?? 0
    func visit(_ node: inout Node) {
        for index in node.children.indices { visit(&node.children[index]) }
        guard node.id == "chat_bubble_item_view" else { return }
        let evidence = colorEvidence(image, row: node)
        let right = evidence.1 >= 80 && evidence.1 > evidence.0 * 2 && evidence.1 > evidence.3 * 2
        let left = evidence.2 >= 80 && evidence.2 > evidence.3 * 2 && evidence.2 > evidence.0 * 2
        if right {
            node.x = leftX + listWidth * 0.62
            node.width = listWidth * 0.33
            node.side = "right"
            node.confidence = "high"
            node.evidence = "green_right"
        } else if left {
            node.x = leftX + listWidth * 0.05
            node.width = listWidth * 0.33
            node.side = "left"
            node.confidence = "high"
            node.evidence = "gray_left"
        } else {
            node.side = "unknown"
            node.confidence = "none"
            node.evidence = "no_distinct_bubble_color"
        }
    }
    visit(&root)
}

if command == "press" {
    guard CommandLine.arguments.count > 2 else { json(Result(ok: false, error: "missing_id", trusted: trusted)); exit(2) }
    let wanted = CommandLine.arguments[2]
    if wanted.hasPrefix("session_item_") {
        let chat = String(wanted.dropFirst("session_item_".count))
        let before = tree(window)
        guard openSession(before, chat: chat) else {
            json(Result(ok: false, error: "session_open_failed", trusted: trusted)); exit(1)
        }
        json(Result(ok: true, trusted: trusted, windowCount: 1)); exit(0)
    }
    guard let target = locate(window, id: wanted), AXUIElementPerformAction(target, kAXPressAction as CFString) == .success else {
        json(Result(ok: false, error: "press_failed", trusted: trusted)); exit(1)
    }
    json(Result(ok: true, trusted: trusted, windowCount: 1)); exit(0)
}

if command == "scroll" {
    let delta = Int32(CommandLine.arguments.dropFirst(2).first ?? "-8") ?? -8
    let current = tree(window)
    guard let list = find(current, id: "session_list"), let x = list.x, let y = list.y, let w = list.width, let h = list.height else {
        json(Result(ok: false, error: "session_list_unavailable", trusted: trusted)); exit(1)
    }
    let source = CGEventSource(stateID: .hidSystemState)
    let point = CGPoint(x: x + w / 2, y: y + h / 2)
    let event = CGEvent(scrollWheelEvent2Source: source, units: .line, wheelCount: 1, wheel1: delta, wheel2: 0, wheel3: 0)
    event?.location = point
    event?.postToPid(wechatPID)
    usleep(150_000)
    json(Result(ok: true, trusted: trusted, windowCount: 1)); exit(0)
}

if command == "send" {
    guard CommandLine.arguments.count >= 5 else { json(Result(ok: false, error: "usage_send_chat_anchor_text", trusted: trusted)); exit(2) }
    let chat = CommandLine.arguments[2]
    let anchor = CommandLine.arguments[3]
    let text = CommandLine.arguments.dropFirst(4).joined(separator: " ")
    let before = tree(window)
    guard let label = find(before, id: "current_chat_name_label"), label.value == chat || label.title == chat else {
        json(Result(ok: false, error: "chat_changed", trusted: trusted)); exit(1)
    }
    guard let input = find(before, id: "chat_input_field"), input.value.isEmpty || input.value == text else {
        json(Result(ok: false, error: "draft_or_input_busy", trusted: trusted)); exit(1)
    }
    guard let messages = find(before, id: "chat_message_list"), descendants(messages).contains(where: { $0.value.contains(anchor) || $0.title.contains(anchor) }) else {
        json(Result(ok: false, error: "anchor_changed", trusted: trusted)); exit(1)
    }
    func locate(_ e: AXUIElement, id: String) -> AXUIElement? {
        if str(e, "AXIdentifier" as CFString) == id { return e }
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &v) == .success, let cs = v as? [AXUIElement] else { return nil }
        for c in cs { if let hit = locate(c, id: id) { return hit } }
        return nil
    }
    guard let inputElement = locate(window, id: "chat_input_field") else { json(Result(ok: false, error: "input_unavailable", trusted: trusted)); exit(1) }
    if input.value != text {
        guard AXUIElementSetAttributeValue(inputElement, kAXValueAttribute as CFString, text as CFString) == .success else { json(Result(ok: false, error: "input_set_failed", trusted: trusted)); exit(1) }
    }
    let afterType = tree(window)
    guard let afterLabel = find(afterType, id: "current_chat_name_label"), (afterLabel.value == chat || afterLabel.title == chat), let typed = find(afterType, id: "chat_input_field"), typed.value == text else { json(Result(ok: false, error: "ui_changed_after_typing", trusted: trusted)); exit(1) }
    _ = NSRunningApplication(processIdentifier: wechatPID)?.activate()
    _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    _ = AXUIElementSetAttributeValue(inputElement, kAXFocusedAttribute as CFString, true as CFBoolean)
    usleep(80_000)
    let source = CGEventSource(stateID: .hidSystemState)
    let down = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: true)
    let up = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: false)
    down?.postToPid(wechatPID); up?.postToPid(wechatPID)
    usleep(150_000)
    let afterSend = tree(window)
    guard let remaining = find(afterSend, id: "chat_input_field"), remaining.value.isEmpty else {
        json(Result(ok: false, error: "send_not_accepted", trusted: trusted)); exit(1)
    }
    json(Result(ok: true, trusted: trusted, windowCount: 1)); exit(0)
}

json(Result(ok: false, error: "unknown_command", trusted: trusted)); exit(2)
