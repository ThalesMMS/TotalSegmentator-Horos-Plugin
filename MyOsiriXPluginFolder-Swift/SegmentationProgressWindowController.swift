import Cocoa

final class SegmentationProgressWindowController: NSWindowController {
    private let textView = NSTextView(frame: .zero)
    private let progressIndicator = NSProgressIndicator(frame: .zero)
    private let cancelButton = NSButton(frame: .zero)
    private var cancelHandler: (() -> Void)?

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 340),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "TotalSegmentator Progress"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        configureContent()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func start() {
        progressIndicator.startAnimation(nil)
        append("Starting TotalSegmentator…")
    }

    func append(_ message: String) {
        guard let textStorage = textView.textStorage else { return }
        let normalized = message.hasSuffix("\n") ? message : message + "\n"
        let attributed = NSAttributedString(string: normalized)
        textStorage.append(attributed)
        textView.scrollToEndOfDocument(nil)
    }

    func setCancelHandler(_ handler: @escaping () -> Void) {
        cancelHandler = handler
        cancelButton.isHidden = false
        cancelButton.isEnabled = true
    }

    func markProcessFinished() {
        progressIndicator.stopAnimation(nil)
        cancelButton.isEnabled = false
        cancelHandler = nil
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
        window?.orderOut(nil)
        super.close()
    }

    private func configureContent() {
        guard let contentView = window?.contentView else { return }

        textView.isEditable = false
        textView.isSelectable = true
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = NSSize(width: 4, height: 8)

        let scrollView = NSScrollView(frame: .zero)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.documentView = textView
        scrollView.borderType = .bezelBorder

        progressIndicator.translatesAutoresizingMaskIntoConstraints = false
        progressIndicator.style = .spinning

        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.title = "Cancel"
        cancelButton.target = self
        cancelButton.action = #selector(cancelAction)
        cancelButton.bezelStyle = .rounded
        cancelButton.isHidden = true

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
}
