// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Maksim Ramzaev. Part of RMS MAKS; see LICENSE.

import SwiftUI
import RMSMaxCore

// MARK: - Shared styling (fonts for the custom format attributes)

#if os(macOS)
typealias PFont = NSFont
typealias PColor = NSColor
#else
typealias PFont = UIFont
typealias PColor = UIColor
#endif

enum ComposerStyle {
    static var baseFont: PFont { PFont.systemFont(ofSize: 14) }

    static func font(strong: Bool, emphasized: Bool, mono: Bool) -> PFont {
        let base = baseFont
        #if os(macOS)
        var f: NSFont = mono ? NSFont.monospacedSystemFont(ofSize: base.pointSize, weight: strong ? .bold : .regular) : base
        var mask: NSFontTraitMask = []
        if strong && !mono { mask.insert(.boldFontMask) }
        if emphasized { mask.insert(.italicFontMask) }
        if !mask.isEmpty { f = NSFontManager.shared.convert(f, toHaveTrait: mask) }
        return f
        #else
        if mono { return UIFont.monospacedSystemFont(ofSize: base.pointSize, weight: strong ? .bold : .regular) }
        var t: UIFontDescriptor.SymbolicTraits = []
        if strong { t.insert(.traitBold) }
        if emphasized { t.insert(.traitItalic) }
        return UIFont(descriptor: base.fontDescriptor.withSymbolicTraits(t) ?? base.fontDescriptor, size: base.pointSize)
        #endif
    }

    /// Visible attributes derived from the format attributes of a run.
    static func visual(for attrs: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
        func has(_ f: RichFormat) -> Bool { attrs[f.key] != nil }
        var out: [NSAttributedString.Key: Any] = [
            .font: font(strong: has(.strong), emphasized: has(.emphasized), mono: has(.monospaced)),
        ]
        out[.underlineStyle] = (has(.underline) || attrs[RichKeys.link] != nil) ? NSUnderlineStyle.single.rawValue : 0
        out[.strikethroughStyle] = has(.strikethrough) ? NSUnderlineStyle.single.rawValue : 0
        #if os(macOS)
        let accent = NSColor.controlAccentColor
        out[.foregroundColor] = (attrs[RichKeys.link] != nil || attrs[RichKeys.mention] != nil) ? accent : (has(.quote) ? NSColor.secondaryLabelColor : NSColor.labelColor)
        out[.backgroundColor] = has(.quote) ? NSColor.secondaryLabelColor.withAlphaComponent(0.12) : NSColor.clear
        #else
        out[.foregroundColor] = (attrs[RichKeys.link] != nil || attrs[RichKeys.mention] != nil) ? UIColor.tintColor : (has(.quote) ? UIColor.secondaryLabel : UIColor.label)
        out[.backgroundColor] = has(.quote) ? UIColor.secondaryLabel.withAlphaComponent(0.12) : UIColor.clear
        #endif
        return out
    }

    static func restyle(_ s: NSMutableAttributedString, range: NSRange? = nil) {
        let full = range ?? NSRange(location: 0, length: s.length)
        guard full.length > 0 else { return }
        s.enumerateAttributes(in: full, options: []) { attrs, r, _ in s.addAttributes(visual(for: attrs), range: r) }
    }
}

/// Shows an alert with a text field and returns the entered link, or nil.
@MainActor func askForLink(current: String?) -> String? {
    #if os(macOS)
    let alert = NSAlert()
    alert.messageText = "Добавить ссылку"
    alert.informativeText = "Адрес, на который будет вести выделенный текст"
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
    field.stringValue = current ?? "https://"
    alert.accessoryView = field
    alert.addButton(withTitle: "Добавить"); alert.addButton(withTitle: "Отмена")
    guard alert.runModal() == .alertFirstButtonReturn else { return nil }
    let v = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    return v.isEmpty ? nil : v
    #else
    return nil
    #endif
}

#if os(macOS)

// MARK: - macOS: NSTextView composer

final class ComposerTextView: NSTextView {
    var onSend: () -> Void = {}
    var onPasteImage: () -> Bool = { false }
    var onEdited: () -> Void = {}
    var placeholder = ""

    override func keyDown(with e: NSEvent) {
        let isReturn = e.keyCode == 36 || e.keyCode == 76
        if isReturn, !hasMarkedText() {
            let cmdSends = UserDefaults.standard.string(forKey: "rmsmaks.sendKey") == "cmdReturn"
            let sends = cmdSends ? e.modifierFlags.contains(.command) : e.modifierFlags.intersection([.shift, .option]).isEmpty
            if sends { onSend() } else { insertNewlineIgnoringFieldEditor(nil) }   // otherwise a new line
            return
        }
        super.keyDown(with: e)
    }

    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        guard window?.firstResponder === self else { return super.performKeyEquivalent(with: e) }
        let f = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let cmd = f == .command, cmdShift = f == [.command, .shift]
        // ⌘V with an image on the clipboard: NSTextView disables Paste for image-only content, so handle it here.
        if e.keyCode == 9, cmd, ClipboardImage.hasImage, onPasteImage() { return true }
        switch (e.keyCode, cmd, cmdShift) {
        case (11, true, _): toggle(.strong); return true                 // ⌘B
        case (34, true, _): toggle(.emphasized); return true             // ⌘I
        case (32, true, _): toggle(.underline); return true              // ⌘U
        case (7, _, true): toggle(.strikethrough); return true           // ⇧⌘X
        case (47, _, true): toggle(.quote); return true                  // ⇧⌘.
        case (46, _, true): toggle(.monospaced); return true             // ⇧⌘M
        case (40, true, _): addLink(); return true                       // ⌘K
        case (45, _, true): clearFormatting(); return true               // ⇧⌘N
        default: return super.performKeyEquivalent(with: e)
        }
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(NSText.paste(_:)), ClipboardImage.hasImage { return true }   // Edit ▸ Paste with a screenshot
        return super.validateUserInterfaceItem(item)
    }

    override func paste(_ sender: Any?) {
        // A screenshot or an image file on the clipboard is sent as a photo; everything else is pasted as plain text.
        if ClipboardImage.hasImage, onPasteImage() { return }
        pasteAsPlainText(sender)
    }

    override func draw(_ rect: NSRect) {
        super.draw(rect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        placeholder.draw(at: NSPoint(x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0), y: textContainerInset.height),
                         withAttributes: [.font: ComposerStyle.baseFont, .foregroundColor: NSColor.placeholderTextColor])
    }

    // MARK: formatting

    func toggle(_ f: RichFormat) {
        let r = selectedRange()
        if r.length == 0 {
            var ta = typingAttributes
            if ta[f.key] != nil { ta.removeValue(forKey: f.key) } else { ta[f.key] = true }
            typingAttributes = ta.merging(ComposerStyle.visual(for: ta)) { _, new in new }
            return
        }
        var all = true
        textStorage?.enumerateAttribute(f.key, in: r, options: []) { v, _, stop in if v == nil { all = false; stop.pointee = true } }
        mutate(r) { s in
            if all { s.removeAttribute(f.key, range: r) } else { s.addAttribute(f.key, value: true, range: r) }
        }
    }

    func addLink() {
        let r = selectedRange()
        guard r.length > 0 else { NSSound.beep(); return }
        var current: String?
        textStorage?.enumerateAttribute(RichKeys.link, in: r, options: []) { v, _, _ in current = current ?? (v as? String) }
        guard let url = askForLink(current: current) else { return }
        mutate(r) { $0.addAttribute(RichKeys.link, value: url, range: r) }
    }

    func clearFormatting() {
        var r = selectedRange()
        if r.length == 0 { r = NSRange(location: 0, length: (string as NSString).length) }
        mutate(r) { s in
            for f in RichFormat.allCases { s.removeAttribute(f.key, range: r) }
            s.removeAttribute(RichKeys.link, range: r)
        }
    }

    private func mutate(_ r: NSRange, _ change: (NSMutableAttributedString) -> Void) {
        guard let storage = textStorage, shouldChangeText(in: r, replacementString: nil) else { return }
        storage.beginEditing()
        change(storage)
        ComposerStyle.restyle(storage, range: r)
        storage.endEditing()
        didChangeText()
    }

    // MARK: context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        let sub = NSMenu(title: "Форматирование")
        func item(_ title: String, _ key: String, _ mods: NSEvent.ModifierFlags, _ action: Selector) {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods; i.target = self; sub.addItem(i)
        }
        item("Жирный", "b", .command, #selector(menuStrong))
        item("Курсив", "i", .command, #selector(menuEmphasized))
        item("Подчёркнутый", "u", .command, #selector(menuUnderline))
        item("Зачёркнутый", "x", [.command, .shift], #selector(menuStrike))
        item("Цитата", ".", [.command, .shift], #selector(menuQuote))
        item("Моноширинный", "m", [.command, .shift], #selector(menuMono))
        sub.addItem(.separator())
        item("Добавить ссылку", "k", .command, #selector(menuLink))
        sub.addItem(.separator())
        item("Без форматирования", "n", [.command, .shift], #selector(menuClear))
        let parent = NSMenuItem(title: "Форматирование", action: nil, keyEquivalent: "")
        parent.submenu = sub
        let at = max(0, menu.items.count - 2)   // before the trailing «Select All»-like items
        menu.insertItem(.separator(), at: at)
        menu.insertItem(parent, at: at + 1)
        return menu
    }

    @objc private func menuStrong() { toggle(.strong) }
    @objc private func menuEmphasized() { toggle(.emphasized) }
    @objc private func menuUnderline() { toggle(.underline) }
    @objc private func menuStrike() { toggle(.strikethrough) }
    @objc private func menuQuote() { toggle(.quote) }
    @objc private func menuMono() { toggle(.monospaced) }
    @objc private func menuLink() { addLink() }
    @objc private func menuClear() { clearFormatting() }
}

/// Multi-line editor: Return sends, Shift+Return / Option+Return starts a new line, Telegram-style formatting
/// (⌘B ⌘I ⌘U ⇧⌘X ⇧⌘. ⇧⌘M ⌘K ⇧⌘N and the «Форматирование» context menu). Pasted text is plain; pasted images go to `onPasteImage`.
struct ComposerEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var elements: [TextElement]
    @Binding var height: CGFloat
    var placeholder: String
    var onSend: () -> Void
    var onPasteImage: () -> Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let tv = ComposerTextView()
        tv.isRichText = true
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.font = ComposerStyle.baseFont
        tv.textColor = .labelColor
        tv.textContainerInset = NSSize(width: 4, height: 6)
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.placeholder = placeholder
        tv.delegate = context.coordinator
        context.coordinator.textView = tv
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.documentView = tv
        context.coordinator.load(into: tv)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tv = scroll.documentView as? ComposerTextView else { return }
        tv.placeholder = placeholder
        tv.onSend = onSend
        tv.onPasteImage = onPasteImage
        if tv.string != text || elements != context.coordinator.lastElements { context.coordinator.load(into: tv) }
        context.coordinator.updateHeight()
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerEditor
        weak var textView: ComposerTextView?
        var lastElements: [TextElement] = []
        private var loading = false

        init(_ p: ComposerEditor) { parent = p }

        func load(into tv: ComposerTextView) {
            loading = true
            let s = RichText.attributed(parent.text, elements: parent.elements)
            s.addAttributes([.font: ComposerStyle.baseFont, .foregroundColor: NSColor.labelColor], range: NSRange(location: 0, length: s.length))
            ComposerStyle.restyle(s)
            tv.textStorage?.setAttributedString(s)
            tv.typingAttributes = [.font: ComposerStyle.baseFont, .foregroundColor: NSColor.labelColor]
            tv.setSelectedRange(NSRange(location: s.length, length: 0))
            lastElements = parent.elements
            loading = false
            updateHeight()
        }

        func textDidChange(_ n: Notification) {
            guard !loading, let tv = textView, let storage = tv.textStorage else { return }
            let els = RichText.elements(from: storage)
            lastElements = els
            parent.text = tv.string
            parent.elements = els
            updateHeight()
        }

        func updateHeight() {
            guard let tv = textView, let lm = tv.layoutManager, let tc = tv.textContainer else { return }
            lm.ensureLayout(for: tc)
            let h = ceil(lm.usedRect(for: tc).height) + tv.textContainerInset.height * 2
            let clamped = min(max(h, 30), 150)
            if abs(parent.height - clamped) > 0.5 { DispatchQueue.main.async { self.parent.height = clamped } }
        }
    }
}

#else

// MARK: - iOS: UITextView composer

final class ComposerUITextView: UITextView {
    var placeholder = "" { didSet { setNeedsDisplay() } }
    override func draw(_ rect: CGRect) {
        super.draw(rect)
        guard text.isEmpty, !placeholder.isEmpty else { return }
        (placeholder as NSString).draw(at: CGPoint(x: textContainerInset.left + textContainer.lineFragmentPadding, y: textContainerInset.top),
                                       withAttributes: [.font: ComposerStyle.baseFont, .foregroundColor: UIColor.placeholderText])
    }
}

/// Return inserts a new line (the send button sends); formatting through the edit menu.
struct ComposerEditor: UIViewRepresentable {
    @Binding var text: String
    @Binding var elements: [TextElement]
    @Binding var height: CGFloat
    var placeholder: String
    var onSend: () -> Void
    var onPasteImage: () -> Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> ComposerUITextView {
        let tv = ComposerUITextView()
        tv.backgroundColor = .clear
        tv.font = ComposerStyle.baseFont
        tv.textContainerInset = UIEdgeInsets(top: 6, left: 4, bottom: 6, right: 4)
        tv.delegate = context.coordinator
        tv.placeholder = placeholder
        context.coordinator.textView = tv
        context.coordinator.load(into: tv)
        return tv
    }

    func updateUIView(_ tv: ComposerUITextView, context: Context) {
        context.coordinator.parent = self
        tv.placeholder = placeholder
        if tv.text != text || elements != context.coordinator.lastElements { context.coordinator.load(into: tv) }
        context.coordinator.updateHeight()
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ComposerEditor
        weak var textView: ComposerUITextView?
        var lastElements: [TextElement] = []
        private var loading = false

        init(_ p: ComposerEditor) { parent = p }

        func load(into tv: ComposerUITextView) {
            loading = true
            let s = RichText.attributed(parent.text, elements: parent.elements)
            s.addAttributes([.font: ComposerStyle.baseFont, .foregroundColor: UIColor.label], range: NSRange(location: 0, length: s.length))
            ComposerStyle.restyle(s)
            tv.attributedText = s
            tv.typingAttributes = [.font: ComposerStyle.baseFont, .foregroundColor: UIColor.label]
            lastElements = parent.elements
            loading = false
            updateHeight()
        }

        func textViewDidChange(_ tv: UITextView) {
            guard !loading else { return }
            let els = RichText.elements(from: tv.textStorage)
            lastElements = els
            parent.text = tv.text
            parent.elements = els
            updateHeight()
        }

        func updateHeight() {
            guard let tv = textView else { return }
            let h = tv.sizeThatFits(CGSize(width: max(tv.bounds.width, 200), height: .greatestFiniteMagnitude)).height
            let clamped = min(max(h, 34), 150)
            if abs(parent.height - clamped) > 0.5 { DispatchQueue.main.async { self.parent.height = clamped } }
        }

        func toggle(_ f: RichFormat, in tv: UITextView) {
            let r = tv.selectedRange
            guard r.length > 0 else { return }
            var all = true
            tv.textStorage.enumerateAttribute(f.key, in: r, options: []) { v, _, stop in if v == nil { all = false; stop.pointee = true } }
            tv.textStorage.beginEditing()
            if all { tv.textStorage.removeAttribute(f.key, range: r) } else { tv.textStorage.addAttribute(f.key, value: true, range: r) }
            ComposerStyle.restyle(tv.textStorage, range: r)
            tv.textStorage.endEditing()
            textViewDidChange(tv)
        }

        func textView(_ tv: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
            guard range.length > 0 else { return UIMenu(children: suggestedActions) }
            let actions = RichFormat.allCases.map { f in UIAction(title: f.title) { [weak self, weak tv] _ in if let tv { self?.toggle(f, in: tv) } } }
            let clear = UIAction(title: "Без форматирования") { [weak self, weak tv] _ in
                guard let tv else { return }
                for f in RichFormat.allCases { tv.textStorage.removeAttribute(f.key, range: range) }
                tv.textStorage.removeAttribute(RichKeys.link, range: range)
                ComposerStyle.restyle(tv.textStorage, range: range)
                self?.textViewDidChange(tv)
            }
            return UIMenu(children: suggestedActions + [UIMenu(title: "Форматирование", children: actions + [clear])])
        }
    }
}

#endif
