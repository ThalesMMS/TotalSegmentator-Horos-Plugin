import Cocoa

final class SegmentationProgressWindowController: NSWindowController {
    private lazy var textView: NSTextView = {
        let view = NSTextView(frame: .zero)
        view.isEditable = false
        view.isSelectable = true
        view.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        view.textContainerInset = NSSize(width: 4, height: 8)
        view.minSize = NSSize(width: 0, height: 0)
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        if let container = view.textContainer {
            container.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            container.widthTracksTextView = true
        }
        return view
    }()

    private lazy var progressIndicator: NSProgressIndicator = {
        let indicator = NSProgressIndicator(frame: .zero)
        indicator.translatesAutoresizingMaskIntoConstraints = false
        indicator.style = .spinning
        return indicator
    }()

    private lazy var cancelButton: NSButton = {
        let button = NSButton(frame: .zero)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.title = "Cancel"
        button.target = self
        button.action = #selector(cancelAction)
        button.bezelStyle = .rounded
        button.isHidden = true
        return button
    }()

    private var cancelHandler: (() -> Void)?
    private var didConfigureUI = false

    init() {
        super.init(window: nil)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    func start() {
        performOnMain { controller in
            controller.progressIndicator.startAnimation(nil)
            controller.append("Starting TotalSegmentator…")
        }
    }

    func append(_ message: String) {
        performOnMain { controller in
            guard let textStorage = controller.textView.textStorage else { return }
            let normalized = message.hasSuffix("\n") ? message : message + "\n"
            let attributed = NSAttributedString(string: normalized)
            textStorage.append(attributed)
            controller.textView.scrollToEndOfDocument(nil)
        }
    }

    func setCancelHandler(_ handler: @escaping () -> Void) {
        performOnMain { controller in
            controller.cancelHandler = handler
            controller.cancelButton.isHidden = false
            controller.cancelButton.isEnabled = true
        }
    }

    func markProcessFinished() {
        performOnMain { controller in
            controller.progressIndicator.stopAnimation(nil)
            controller.cancelButton.isEnabled = false
            controller.cancelHandler = nil
        }
    }

    func close(after delay: TimeInterval) {
        if delay <= 0 {
            close()
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.close()
        }
    }

    override func close() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.close()
            }
            return
        }

        window?.orderOut(nil)
        super.close()
    }

    override func showWindow(_ sender: Any?) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.showWindow(sender)
            }
            return
        }

        ensureWindow()
        super.showWindow(sender)
    }

    private func ensureWindow() {
        precondition(Thread.isMainThread, "UI updates must occur on the main thread.")

        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 340),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "TotalSegmentator Progress"
            window.isReleasedWhenClosed = false
            self.window = window
        }

        configureContentIfNeeded()
    }

    private func configureContentIfNeeded() {
        guard let contentView = window?.contentView, !didConfigureUI else { return }
        didConfigureUI = true

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.documentView = textView
        scrollView.borderType = .bezelBorder

        textView.backgroundColor = NSColor.textBackgroundColor
        textView.textColor = NSColor.labelColor
        textView.frame = scrollView.contentView.bounds

        contentView.addSubview(scrollView)
        contentView.addSubview(progressIndicator)
        contentView.addSubview(cancelButton)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            scrollView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            scrollView.bottomAnchor.constraint(equalTo: progressIndicator.topAnchor, constant: -16),

            progressIndicator.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            progressIndicator.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -18),

            cancelButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            cancelButton.centerYAnchor.constraint(equalTo: progressIndicator.centerYAnchor),
            cancelButton.leadingAnchor.constraint(greaterThanOrEqualTo: progressIndicator.trailingAnchor, constant: 12)
        ])
    }

    @objc private func cancelAction() {
        cancelButton.isEnabled = false
        let handler = cancelHandler
        cancelHandler = nil
        handler?()
        append("Cancellation requested…")
    }

    private func performOnMain(_ block: @escaping (SegmentationProgressWindowController) -> Void) {
        let work = { [weak self] in
            guard let self = self else { return }
            self.ensureWindow()
            block(self)
        }

        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }
}
