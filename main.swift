import Cocoa
import WebKit
import Carbon.HIToolbox

// Hark Quick Access v0.2
// Compact native "Ask Hark" bar. Grabs the front Yab tab through `yab mcp`.
// The Hark web view only exists once you send, and is torn down after idle time.

let kURL = "harkURL"
let EXPANDED_W: CGFloat = 440
let BAR_W: CGFloat = 420, BAR_H: CGFloat = 64
let IDLE_TEARDOWN: TimeInterval = 180   // free the web view 3 min after you collapse it
let YAB = NSHomeDirectory() + "/.local/bin/yab"

// MARK: - Yab MCP (short-lived stdio client)
enum YabMCP {
  static func call(_ tool: String, _ args: [String: Any], timeout: TimeInterval = 8) -> String? {
    guard FileManager.default.isExecutableFile(atPath: YAB) else { return nil }
    let p = Process(); p.executableURL = URL(fileURLWithPath: YAB); p.arguments = ["mcp"]
    let inP = Pipe(), outP = Pipe(); p.standardInput = inP; p.standardOutput = outP; p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return nil }
    func send(_ o: [String: Any]) {
      if let d = try? JSONSerialization.data(withJSONObject: o) { inP.fileHandleForWriting.write(d); inP.fileHandleForWriting.write("\n".data(using: .utf8)!) }
    }
    send(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "hark-quick-access", "version": "0.2"]]])
    send(["jsonrpc": "2.0", "method": "notifications/initialized"])
    send(["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": tool, "arguments": args]])
    var buf = Data(); var result: String?
    let deadline = Date().addingTimeInterval(timeout)
    let fh = outP.fileHandleForReading
    while Date() < deadline, result == nil {
      let chunk = fh.availableData
      if chunk.isEmpty { break }
      buf.append(chunk)
      while let nl = buf.firstIndex(of: 0x0A) {
        let line = buf[buf.startIndex..<nl]; buf.removeSubrange(buf.startIndex...nl)
        guard let o = try? JSONSerialization.jsonObject(with: line) as? [String: Any], (o["id"] as? Int) == 2 else { continue }
        let content = ((o["result"] as? [String: Any])?["content"] as? [[String: Any]]) ?? []
        result = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
      }
    }
    p.terminate()
    return result
  }

  struct Tab { let id: String; let title: String; let url: String }
  static func frontTab() -> Tab? {
    guard let s = call("tabs", [:]) else { return nil }
    for line in s.split(separator: "\n") where line.contains("[user] (in front)") {
      let l = String(line)
      let id = String(l.prefix(while: { $0 != " " }))
      var rest = l.components(separatedBy: "(in front) ").dropFirst().joined(separator: "(in front) ")
      var url = ""
      if let r = rest.range(of: ", http", options: .backwards) { url = String(rest[rest.index(r.lowerBound, offsetBy: 2)...]); rest = String(rest[..<r.lowerBound]) }
      if url.contains("hark.com") { return nil }
      return Tab(id: id, title: rest, url: url)
    }
    return nil
  }
  static func text(_ tab: String) -> String { (call("text", ["tab": tab], timeout: 10) ?? "") }
}

// MARK: - Windows
final class Panel: NSPanel {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { true }
}

final class App: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKUIDelegate, NSTextFieldDelegate {
  var bar: Panel!, field: NSTextField!, chip: NSButton!, spinner: NSProgressIndicator!
  var big: Panel?, web: WKWebView?
  var tab: YabMCP.Tab?, attach = true
  var teardown: Timer?
  var hotRefs: [EventHotKeyRef?] = []
  var status: NSStatusItem!
  var pending: String?

  func applicationDidFinishLaunching(_ n: Notification) {
    NSApp.setActivationPolicy(.accessory)
    buildBar(); buildMenu(); registerHotKeys()
    if UserDefaults.standard.string(forKey: kURL) == nil { askURL() }
    showBar()
  }

  var screen: NSRect { (NSScreen.main ?? NSScreen.screens[0]).visibleFrame }

  // Compact bar
  func buildBar() {
    let r = NSRect(x: screen.maxX - BAR_W - 16, y: screen.minY + 16, width: BAR_W, height: BAR_H)
    bar = Panel(contentRect: r, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    bar.isFloatingPanel = true; bar.level = .floating; bar.hidesOnDeactivate = false
    bar.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    bar.backgroundColor = .clear; bar.isOpaque = false; bar.hasShadow = true; bar.isMovableByWindowBackground = true
    let fx = NSVisualEffectView(frame: NSRect(origin: .zero, size: r.size))
    fx.material = .hudWindow; fx.state = .active; fx.wantsLayer = true; fx.layer?.cornerRadius = 16; fx.layer?.masksToBounds = true
    bar.contentView = fx

    field = NSTextField(frame: NSRect(x: 14, y: 30, width: BAR_W - 28, height: 24))
    field.placeholderString = "Ask Hark…"; field.isBordered = false; field.drawsBackground = false
    field.focusRingType = .none; field.font = .systemFont(ofSize: 15); field.delegate = self
    fx.addSubview(field)

    chip = NSButton(title: "", target: self, action: #selector(toggleAttach))
    chip.frame = NSRect(x: 10, y: 6, width: BAR_W - 60, height: 20); chip.isBordered = false
    chip.font = .systemFont(ofSize: 11); chip.alignment = .left; chip.contentTintColor = .secondaryLabelColor
    chip.lineBreakMode = .byTruncatingTail
    fx.addSubview(chip)

    spinner = NSProgressIndicator(frame: NSRect(x: BAR_W - 34, y: 6, width: 18, height: 18))
    spinner.style = .spinning; spinner.controlSize = .small; spinner.isDisplayedWhenStopped = false
    fx.addSubview(spinner)
  }

  func updateChip() {
    if let t = tab { chip.title = (attach ? "📎 " : "⊘ ") + t.title + (attach ? "" : "  (not attached)") }
    else { chip.title = "No Yab tab in front" }
  }

  @objc func toggleAttach() { attach.toggle(); updateChip() }

  func refreshTab() {
    chip.title = "Reading your Yab tab…"
    DispatchQueue.global(qos: .userInitiated).async {
      let t = YabMCP.frontTab()
      DispatchQueue.main.async { self.tab = t; self.updateChip() }
    }
  }

  func showBar() {
    bar.setFrameOrigin(NSPoint(x: screen.maxX - BAR_W - 16, y: screen.minY + 16))
    NSApp.activate(ignoringOtherApps: true)
    bar.makeKeyAndOrderFront(nil); bar.makeFirstResponder(field)
    refreshTab()
  }

  // Enter sends, Esc hides
  func control(_ c: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
    if sel == #selector(NSResponder.insertNewline(_:)) { submit(); return true }
    if sel == #selector(NSResponder.cancelOperation(_:)) { bar.orderOut(nil); return true }
    return false
  }

  func submit() {
    let q = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !q.isEmpty else { return }
    spinner.startAnimation(nil); field.isEnabled = false
    let t = attach ? tab : nil
    DispatchQueue.global(qos: .userInitiated).async {
      var msg = q
      if let t = t { msg += "\n\n[Yab tab \(t.id)] \(t.title)\n\(t.url)" }
      DispatchQueue.main.async {
        self.spinner.stopAnimation(nil); self.field.isEnabled = true; self.field.stringValue = ""
        self.bar.orderOut(nil); self.expand(sending: msg)
      }
    }
  }

  // Expanded Hark panel (web view created on demand)
  func expand(sending msg: String? = nil) {
    teardown?.invalidate(); teardown = nil
    let frame = NSRect(x: screen.maxX - EXPANDED_W, y: screen.minY, width: EXPANDED_W, height: screen.height)
    if big == nil {
      let p = Panel(contentRect: frame, styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel], backing: .buffered, defer: false)
      p.titleVisibility = .hidden; p.titlebarAppearsTransparent = true; p.isFloatingPanel = true; p.level = .floating
      p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]; p.hidesOnDeactivate = false; p.isReleasedWhenClosed = false
      big = p
    }
    if web == nil {
      let cfg = WKWebViewConfiguration(); cfg.websiteDataStore = .default()
      cfg.mediaTypesRequiringUserActionForPlayback = .all
      let w = WKWebView(frame: .zero, configuration: cfg)
      w.navigationDelegate = self; w.uiDelegate = self
      w.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
      big!.contentView = w; web = w
      pending = msg
      if let s = UserDefaults.standard.string(forKey: kURL), let u = URL(string: s) { w.load(URLRequest(url: u)) }
    } else if let m = msg { inject(m) }
    big!.setFrame(frame, display: true)
    NSApp.activate(ignoringOtherApps: true); big!.makeKeyAndOrderFront(nil)
  }

  func collapse() {
    big?.orderOut(nil)
    teardown?.invalidate()
    teardown = Timer.scheduledTimer(withTimeInterval: IDLE_TEARDOWN, repeats: false) { [weak self] _ in self?.freeWeb() }
  }

  func freeWeb() {
    web?.stopLoading(); web?.loadHTMLString("", baseURL: nil)
    big?.contentView = nil; web = nil
  }

  func webView(_ w: WKWebView, didFinish nav: WKNavigation!) {
    if let m = pending { pending = nil; DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { self.inject(m) } }
  }

  // Put text in Hark's chat box and send it. Retries while the page is still drawing.
  func inject(_ text: String, tries: Int = 0, nonce: String = UUID().uuidString) {
    let arg = String(data: try! JSONSerialization.data(withJSONObject: [text, nonce]), encoding: .utf8)!
    let js = """
    (function(t,n){if(window.__hd===n)return 'ok';
    const b=document.querySelector("textarea,[contenteditable='true'],[role='textbox']");if(!b)return 'nobox';
    window.__hd=n;b.focus();
    const setv=v=>{if(b.tagName==='TEXTAREA'){Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype,'value').set.call(b,v);b.dispatchEvent(new Event('input',{bubbles:true}));}
      else{document.execCommand('selectAll');if(v)document.execCommand('insertText',false,v);else document.execCommand('delete');}};
    const cur=()=>b.tagName==='TEXTAREA'?b.value:b.innerText;
    setv(t);
    setTimeout(()=>{const f=b.closest('form');const btn=(f&&f.querySelector('button[type=submit]'))||document.querySelector('button[aria-label*="send" i]');
      if(btn&&!btn.disabled)btn.click();else b.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',code:'Enter',keyCode:13,which:13,bubbles:true}));
      setTimeout(()=>{if(cur().trim()===t.trim())setv('');},900);},200);
    return 'ok';})(\(arg)[0],\(arg)[1])
    """
    web?.evaluateJavaScript(js) { r, _ in
      if (r as? String) != "ok", tries < 10 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.inject(text, tries: tries + 1, nonce: nonce) } }
    }
  }

  // Keep Hark's background visible but cap its animation at ~12 fps to save GPU.
  static let lightenJS = """
  (function(){const raf=window.requestAnimationFrame.bind(window);let last=0;
  window.requestAnimationFrame=function(cb){return raf(function loop(t){if(t-last<80){return raf(loop);}last=t;cb(t);});};
  document.querySelectorAll('video').forEach(v=>v.pause&&v.pause());})();
  """

  func webView(_ w: WKWebView, createWebViewWith c: WKWebViewConfiguration, for a: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
    if let u = a.request.url { w.load(URLRequest(url: u)) }; return nil
  }

  // Menu bar + hotkeys
  func buildMenu() {
    status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    status.button?.title = "H"
    let m = NSMenu()
    m.addItem(withTitle: "Ask Hark  (⌥Space)", action: #selector(hotMain), keyEquivalent: "")
    m.addItem(withTitle: "Open full chat  (⌥⇧Space)", action: #selector(hotFull), keyEquivalent: "")
    m.addItem(withTitle: "Set Hark link…", action: #selector(askURL), keyEquivalent: "")
    m.addItem(.separator())
    let q = m.addItem(withTitle: "Quit Hark Quick Access", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"); q.target = NSApp
    for i in m.items where i.target == nil { i.target = self }
    status.menu = m
  }

  // ⌥Space: bar <-> hidden; if the full chat is open, collapse it.
  @objc func hotMain() {
    if let b = big, b.isVisible { collapse(); return }
    bar.isVisible ? bar.orderOut(nil) : showBar()
  }
  // ⌥⇧Space: full chat open/closed.
  @objc func hotFull() {
    if let b = big, b.isVisible { collapse() } else { bar.orderOut(nil); expand() }
  }

  @objc func askURL() {
    let a = NSAlert(); a.messageText = "Hark link"
    a.informativeText = "Open the Hark chat or project you want this to use, copy its address, and paste it here."
    let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
    f.stringValue = UserDefaults.standard.string(forKey: kURL) ?? "https://"
    a.accessoryView = f; a.addButton(withTitle: "Save"); a.addButton(withTitle: "Cancel")
    NSApp.activate(ignoringOtherApps: true)
    if a.runModal() == .alertFirstButtonReturn, let u = URL(string: f.stringValue.trimmingCharacters(in: .whitespaces)) {
      UserDefaults.standard.set(u.absoluteString, forKey: kURL); freeWeb()
    }
  }

  func registerHotKeys() {
    var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(GetApplicationEventTarget(), { _, ev, _ in
      var id = EventHotKeyID()
      GetEventParameter(ev, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
      let app = NSApp.delegate as! App
      DispatchQueue.main.async { id.id == 1 ? app.hotMain() : app.hotFull() }
      return noErr
    }, 1, &spec, nil, nil)
    for (i, mods) in [(UInt32(1), UInt32(optionKey)), (UInt32(2), UInt32(optionKey | shiftKey))] {
      var ref: EventHotKeyRef?
      RegisterEventHotKey(UInt32(kVK_Space), mods, EventHotKeyID(signature: OSType(0x48524B44), id: i), GetApplicationEventTarget(), 0, &ref)
      hotRefs.append(ref)
    }
  }
}

let app = NSApplication.shared
let d = App(); app.delegate = d
app.run()
