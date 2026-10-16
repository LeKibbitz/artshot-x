import AppKit
import UniformTypeIdentifiers

@MainActor
final class PreviewWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSUserInterfaceValidations {
    var onClose: (() -> Void)?

    private let canvas: AnnotationCanvas
    private let dimensionsLabel = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(labelWithString: "")
    private var undoButton: NSButton?
    private var copyButton: NSButton?
    private var saveButton: NSButton?
    private var copiedReset: DispatchWorkItem?

    private enum Item {
        static let tools = NSToolbarItem.Identifier("ArtShotX.preview.tools")
        static let undo = NSToolbarItem.Identifier("ArtShotX.preview.undo")
        static let copy = NSToolbarItem.Identifier("ArtShotX.preview.copy")
        static let save = NSToolbarItem.Identifier("ArtShotX.preview.save")
    }

    init(image: NSImage) {
        canvas = AnnotationCanvas(image: image)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 720),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "ArtShot X"
        window.subtitle = "Aperçu de la capture"
        window.minSize = NSSize(width: 680, height: 430)
        window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.delegate = self
        window.center()
        window.toolbarStyle = .unified
        let toolbar = NSToolbar(identifier: "ArtShotX.preview")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        configureContent()
        canvas.onChange = { [weak self] in self?.updateState() }
        updateState()
    }

    required init?(coder: NSCoder) { nil }

    private func configureContent() {
        guard let content = window?.contentView else { return }
        canvas.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(canvas)
        let footer = NSStackView(views: [hintLabel, NSView(), dimensionsLabel])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 12
        footer.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(footer)
        for label in [hintLabel, dimensionsLabel] {
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byTruncatingTail
        }
        dimensionsLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            canvas.topAnchor.constraint(equalTo: content.topAnchor),
            canvas.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            canvas.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -8),
            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            footer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),
            footer.heightAnchor.constraint(equalToConstant: 20)
        ])
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Item.tools, Item.undo, .flexibleSpace, Item.copy, Item.save]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: identifier)
        if identifier == Item.tools {
            let control = NSSegmentedControl(labels: ["Aperçu", "Flèche", "Rectangle", "Étapes"],
                                             trackingMode: .selectOne, target: self,
                                             action: #selector(changeTool(_:)))
            control.selectedSegment = 0
            control.setImage(NSImage(systemSymbolName: "eye", accessibilityDescription: nil), forSegment: 0)
            control.setImage(NSImage(systemSymbolName: "arrow.up.right", accessibilityDescription: nil), forSegment: 1)
            control.setImage(NSImage(systemSymbolName: "rectangle", accessibilityDescription: nil), forSegment: 2)
            control.setImage(NSImage(systemSymbolName: "1.circle.fill", accessibilityDescription: nil), forSegment: 3)
            control.setAccessibilityLabel("Outil d’annotation")
            control.isEnabled = canvas.hasImage
            item.view = control
            item.label = "Outils"
            return item
        }
        let button: NSButton
        switch identifier {
        case Item.undo:
            button = makeButton("Annuler", symbol: "arrow.uturn.backward", action: #selector(undoAnnotation(_:)))
            button.keyEquivalent = "z"
            button.keyEquivalentModifierMask = .command
            button.toolTip = "Supprimer la dernière annotation (⌘Z)"
            button.isEnabled = canvas.canUndo
            undoButton = button
        case Item.copy:
            button = makeButton("Copier", symbol: "doc.on.doc", action: #selector(copyImage(_:)))
            button.keyEquivalent = "c"
            button.keyEquivalentModifierMask = .command
            button.toolTip = "Copier l’image avec ses annotations (⌘C)"
            button.isEnabled = canvas.hasImage
            copyButton = button
        case Item.save:
            button = makeButton("Enregistrer…", symbol: "square.and.arrow.down", action: #selector(saveImage(_:)))
            button.keyEquivalent = "s"
            button.keyEquivalentModifierMask = .command
            button.toolTip = "Enregistrer un fichier PNG (⌘S)"
            button.isEnabled = canvas.hasImage
            saveButton = button
        default: return nil
        }
        item.view = button
        item.label = button.title
        return item
    }

    private func makeButton(_ title: String, symbol: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage(),
                              target: self, action: action)
        button.bezelStyle = .rounded
        button.imagePosition = .imageLeading
        button.setAccessibilityLabel(title)
        return button
    }

    @objc private func changeTool(_ sender: NSSegmentedControl) {
        canvas.tool = AnnotationCanvas.Tool(rawValue: sender.selectedSegment) ?? .preview
        window?.makeFirstResponder(canvas)
        updateState()
    }

    @objc private func undoAnnotation(_ sender: Any?) { canvas.undoLastAnnotation() }

    // Standard responder actions also make application Edit/File menus work.
    @objc func copy(_ sender: Any?) { copyImage(sender) }
    @objc func saveDocument(_ sender: Any?) { saveImage(sender) }
    @objc func undo(_ sender: Any?) { undoAnnotation(sender) }

    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)), #selector(saveDocument(_:)): return canvas.hasImage
        case #selector(undo(_:)): return canvas.canUndo
        default: return true
        }
    }

    private func updateState() {
        undoButton?.isEnabled = canvas.canUndo
        copyButton?.isEnabled = canvas.hasImage
        saveButton?.isEnabled = canvas.hasImage
        let size = canvas.pixelSize
        dimensionsLabel.stringValue = canvas.hasImage
            ? "\(Int(size.width)) × \(Int(size.height)) px · Ajusté \(canvas.fitPercentage) %"
            : "Image indisponible"
        switch canvas.tool {
        case .preview: hintLabel.stringValue = "Choisissez un outil pour annoter votre capture."
        case .arrow: hintLabel.stringValue = "Glissez pour tracer une flèche · Échap pour annuler le tracé."
        case .rectangle: hintLabel.stringValue = "Glissez pour tracer un rectangle · Échap pour annuler le tracé."
        case .step: hintLabel.stringValue = "Cliquez pour placer l’étape \(canvas.stepCount + 1) · ⌘Z pour annuler."
        }
    }

    @objc private func copyImage(_ sender: Any?) {
        do {
            let data = try canvas.exportedPNG()
            let item = NSPasteboardItem()
            item.setData(data, forType: .png)
            if let tiff = NSBitmapImageRep(data: data)?.tiffRepresentation {
                item.setData(tiff, forType: .tiff)
            }
            NSPasteboard.general.clearContents()
            guard NSPasteboard.general.writeObjects([item]) else {
                throw NSError(domain: "ArtShotX.Copy", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Impossible de copier l’image dans le presse-papiers."])
            }
            copiedReset?.cancel()
            copyButton?.title = "Copié"
            let reset = DispatchWorkItem { [weak self] in self?.copyButton?.title = "Copier" }
            copiedReset = reset
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: reset)
        } catch { showError(error) }
    }

    @objc private func saveImage(_ sender: Any?) {
        guard let window else { return }
        let panel = NSSavePanel()
        panel.title = "Enregistrer la capture"
        panel.prompt = "Enregistrer"
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'à' HH.mm.ss"
        panel.nameFieldStringValue = "ArtShot X \(formatter.string(from: Date())).png"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            do {
                let data = try self.canvas.exportedPNG()
                try data.write(to: url, options: .atomic)
            } catch { self.showError(error) }
        }
    }

    private func showError(_ error: Error) {
        let alert = NSAlert(error: error)
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    func windowWillClose(_ notification: Notification) {
        copiedReset?.cancel()
        onClose?()
    }
}
