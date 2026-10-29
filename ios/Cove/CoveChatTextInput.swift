import SwiftUI
import UIKit

/// A native, multiline chat editor whose custom sticker panel occupies the
/// keyboard's input-view slot. The text view remains first responder while the
/// two input modes are exchanged, so marked text, selection and undo survive.
struct CoveChatTextInput: UIViewRepresentable {
    @Binding var text: String
    var focused: Bool
    var stickerMode: Bool
    var stickerPanel: AnyView
    var onFocusChange: (Bool) -> Void
    var onCompositionChange: (Bool) -> Void = { _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onFocusChange: onFocusChange, onCompositionChange: onCompositionChange)
    }

    func makeUIView(context: Context) -> PlaceholderTextView {
        let view = PlaceholderTextView()
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.textColor = .label
        view.tintColor = UIColor(CoveStyle.teal)
        view.font = UIFont.preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.isScrollEnabled = false
        view.alwaysBounceVertical = false
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.returnKeyType = .default
        view.keyboardDismissMode = .interactive
        view.accessibilityLabel = "消息输入"
        view.accessibilityIdentifier = "chat.input"
        view.placeholder = "说给 Assistant 听…"
        view.text = text
        view.updatePlaceholder()
        context.coordinator.textView = view
        view.onMoveToWindow = { [weak coordinator = context.coordinator, weak view] in
            guard let coordinator, let view, view.window != nil else { return }
            coordinator.didAttachToWindow(view)
        }
        context.coordinator.installKeyboardObserver()
        context.coordinator.updatePanel(stickerPanel, enabled: stickerMode, for: view)
        return view
    }

    func updateUIView(_ view: PlaceholderTextView, context: Context) {
        context.coordinator.text = $text
        context.coordinator.onFocusChange = onFocusChange
        context.coordinator.onCompositionChange = onCompositionChange

        // Never replace an active IME composition. Its committed delegate
        // update will flow into the binding normally.
        if view.markedTextRange == nil, view.text != text {
            view.text = text
            view.updatePlaceholder()
            view.invalidateIntrinsicContentSize()
        }

        context.coordinator.updatePanel(stickerPanel, enabled: stickerMode, for: view)
        context.coordinator.attachHostIfNeeded(from: view)
        context.coordinator.reconcileFocus(focused, for: view)
        context.coordinator.updateScrolling(for: view)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: PlaceholderTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        let lineHeight = uiView.font?.lineHeight ?? UIFont.preferredFont(forTextStyle: .body).lineHeight
        let minimum = ceil(lineHeight)
        let maximum = ceil(lineHeight * 6)
        let measured = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        let height = min(maximum, max(minimum, ceil(measured)))
        let shouldScroll = measured > maximum + 0.5
        if uiView.isScrollEnabled != shouldScroll { uiView.isScrollEnabled = shouldScroll }
        return CGSize(width: width, height: height)
    }

    static func dismantleUIView(_ view: PlaceholderTextView, coordinator: Coordinator) {
        if view.isFirstResponder { view.resignFirstResponder() }
        view.inputView = nil
        view.onMoveToWindow = nil
        view.delegate = nil
        coordinator.tearDown()
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var text: Binding<String>
        var onFocusChange: (Bool) -> Void
        var onCompositionChange: (Bool) -> Void
        weak var textView: PlaceholderTextView?
        private var host: UIHostingController<AnyView>?
        private var panelInput: StickerInputView?
        private var showingStickerPanel = false
        private var keyboardObserver: NSObjectProtocol?
        private var keyboardHeight: CGFloat = 280
        private var reportedFocus: Bool?
        private var reportedComposition: Bool?
        private var lastRequestedFocus: Bool?
        private var pendingWindowFocus = false

        init(text: Binding<String>, onFocusChange: @escaping (Bool) -> Void,
             onCompositionChange: @escaping (Bool) -> Void) {
            self.text = text
            self.onFocusChange = onFocusChange
            self.onCompositionChange = onCompositionChange
        }

        func textViewDidChange(_ textView: UITextView) {
            text.wrappedValue = textView.text
            (textView as? PlaceholderTextView)?.updatePlaceholder()
            textView.invalidateIntrinsicContentSize()
            updateScrolling(for: textView)
            reportComposition(textView.markedTextRange != nil)
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            reportFocus(true, for: textView)
            reportComposition(textView.markedTextRange != nil)
        }
        func textViewDidEndEditing(_ textView: UITextView) {
            reportFocus(false, for: textView)
            reportComposition(false)
        }
        func textViewDidChangeSelection(_ textView: UITextView) {
            reportComposition(textView.markedTextRange != nil)
        }

        func reconcileFocus(_ requested: Bool, for textView: UITextView) {
            let changed = lastRequestedFocus != requested
            if changed {
                lastRequestedFocus = requested
                pendingWindowFocus = requested && textView.window == nil
            }

            if requested {
                // A native tap may make the view first responder before its
                // asynchronous binding callback arrives. Do not interpret the
                // temporarily stale binding as a request to undo that tap.
                guard !textView.isFirstResponder, changed || pendingWindowFocus else { return }
                guard textView.window != nil else {
                    pendingWindowFocus = true
                    return
                }
                // Retain a deferred request if UIKit cannot accept it yet.
                pendingWindowFocus = !textView.becomeFirstResponder()
            } else {
                pendingWindowFocus = false
                // Only an actual binding transition may dismiss native focus;
                // stale `true` likewise cannot reopen an interactively dismissed
                // keyboard while its delegate callback is in flight.
                if changed, textView.isFirstResponder { textView.resignFirstResponder() }
            }
        }

        func didAttachToWindow(_ view: UITextView) {
            attachHostIfNeeded(from: view)
            if pendingWindowFocus { reconcileFocus(lastRequestedFocus ?? false, for: view) }
        }

        private func reportFocus(_ value: Bool, for textView: UITextView) {
            guard reportedFocus != value else { return }
            reportedFocus = value
            // Delegate callbacks can occur inside updateUIView/becomeFirstResponder.
            // Defer the binding-facing callback and discard a superseded state.
            DispatchQueue.main.async { [weak self, weak textView] in
                guard let self, let textView,
                      self.reportedFocus == value,
                      textView.isFirstResponder == value else { return }
                self.onFocusChange(value)
            }
        }

        private func reportComposition(_ value: Bool) {
            guard reportedComposition != value else { return }
            reportedComposition = value
            DispatchQueue.main.async { [weak self] in
                guard let self, self.reportedComposition == value else { return }
                self.onCompositionChange(value)
            }
        }

        func updateScrolling(for textView: UITextView) {
            let lineHeight = textView.font?.lineHeight ?? UIFont.preferredFont(forTextStyle: .body).lineHeight
            let measured = textView.sizeThatFits(CGSize(width: max(1, textView.bounds.width), height: .greatestFiniteMagnitude)).height
            let shouldScroll = measured > ceil(lineHeight * 6) + 0.5
            if textView.isScrollEnabled != shouldScroll { textView.isScrollEnabled = shouldScroll }
        }

        func updatePanel(_ panel: AnyView, enabled: Bool, for textView: UITextView) {
            if enabled {
                let input = panelInput ?? StickerInputView(
                    frame: CGRect(x: 0, y: 0, width: textView.window?.bounds.width ?? 390, height: keyboardHeight),
                    inputViewStyle: .keyboard)
                input.preferredHeight = keyboardHeight
                panelInput = input
                if let host {
                    host.rootView = panel
                } else {
                    let host = UIHostingController(rootView: panel)
                    // This view IS the keyboard. Applying keyboard safe-area
                    // avoidance inside it shrinks/moves its own content again.
                    host.safeAreaRegions = []
                    host.view.backgroundColor = .clear
                    host.view.translatesAutoresizingMaskIntoConstraints = false
                    let parent = textView.nearestViewController
                    parent?.addChild(host)
                    input.addSubview(host.view)
                    NSLayoutConstraint.activate([
                        host.view.leadingAnchor.constraint(equalTo: input.leadingAnchor),
                        host.view.trailingAnchor.constraint(equalTo: input.trailingAnchor),
                        host.view.topAnchor.constraint(equalTo: input.topAnchor),
                        host.view.bottomAnchor.constraint(equalTo: input.bottomAnchor)
                    ])
                    if let parent { host.didMove(toParent: parent) }
                    self.host = host
                }
                if !showingStickerPanel || textView.inputView !== input {
                    showingStickerPanel = true
                    input.accessibilityIdentifier = "chat.stickerInput"
                    textView.inputView = input
                    if textView.isFirstResponder { textView.reloadInputViews() }
                }
            } else if showingStickerPanel || textView.inputView != nil {
                showingStickerPanel = false
                textView.inputView = nil
                if textView.isFirstResponder { textView.reloadInputViews() }
            }
        }

        func attachHostIfNeeded(from view: UIView) {
            guard let host, host.parent == nil,
                  let parent = view.nearestViewController else { return }
            parent.addChild(host)
            host.didMove(toParent: parent)
        }

        func installKeyboardObserver() {
            guard keyboardObserver == nil else { return }
            keyboardObserver = NotificationCenter.default.addObserver(
                forName: UIResponder.keyboardWillChangeFrameNotification,
                object: nil, queue: .main
            ) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self, !self.showingStickerPanel,
                          let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
                          let window = self.textView?.window else { return }
                    let local = window.convert(frame, from: nil)
                    let height = window.bounds.intersection(local).height
                    guard height >= 160 else { return }
                    self.keyboardHeight = height
                    self.panelInput?.preferredHeight = height
                }
            }
        }

        func tearDown() {
            if let keyboardObserver { NotificationCenter.default.removeObserver(keyboardObserver) }
            keyboardObserver = nil
            host?.willMove(toParent: nil)
            host?.view.removeFromSuperview()
            host?.removeFromParent()
            host = nil
            panelInput = nil
            textView = nil
        }
    }
}

final class PlaceholderTextView: UITextView {
    private let placeholderLabel = UILabel()
    var onMoveToWindow: (() -> Void)?
    var placeholder: String? { didSet { placeholderLabel.text = placeholder } }

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        placeholderLabel.font = UIFont.preferredFont(forTextStyle: .body)
        placeholderLabel.adjustsFontForContentSizeCategory = true
        placeholderLabel.textColor = .placeholderText
        placeholderLabel.isUserInteractionEnabled = false
        addSubview(placeholderLabel)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        onMoveToWindow?()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        placeholderLabel.frame = CGRect(x: 0, y: 0, width: bounds.width, height: font?.lineHeight ?? 24)
    }

    func updatePlaceholder() { placeholderLabel.isHidden = !text.isEmpty }
}

private final class StickerInputView: UIInputView {
    override init(frame: CGRect, inputViewStyle: UIInputView.Style) {
        super.init(frame: frame, inputViewStyle: inputViewStyle)
        allowsSelfSizing = true
        autoresizingMask = [.flexibleWidth]
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    var preferredHeight: CGFloat = 280 {
        didSet {
            guard abs(oldValue - preferredHeight) > 0.5 else { return }
            frame.size.height = preferredHeight
            invalidateIntrinsicContentSize()
        }
    }
    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: preferredHeight) }
    // allowsSelfSizing consults this method, not just intrinsicContentSize.
    // A hosted NavigationStack has no useful compressed height of its own.
    override func systemLayoutSizeFitting(_ targetSize: CGSize) -> CGSize {
        CGSize(width: targetSize.width, height: preferredHeight)
    }
    override func systemLayoutSizeFitting(_ targetSize: CGSize,
                                         withHorizontalFittingPriority horizontalFittingPriority: UILayoutPriority,
                                         verticalFittingPriority: UILayoutPriority) -> CGSize {
        CGSize(width: targetSize.width, height: preferredHeight)
    }
}

/// Only the glyph crossfades, inside a stationary native touch target. Symbol
/// replacement effects create a separate moving layer during keyboard layout.
struct CoveInputModeButton: UIViewRepresentable {
    let stickerMode: Bool
    let reduceMotion: Bool
    let action: () -> Void

    func makeUIView(context: Context) -> Control { Control(frame: .zero) }
    func updateUIView(_ view: Control, context: Context) {
        view.action = action
        view.configure(stickerMode: stickerMode, reduced: reduceMotion)
    }

    final class Control: UIButton {
        private let glyph = UIImageView()
        private var mode: Bool?
        private var reduced = false
        var action: (() -> Void)?
        override init(frame: CGRect) {
            super.init(frame: frame)
            glyph.contentMode = .center
            glyph.isUserInteractionEnabled = false
            glyph.clipsToBounds = true
            addSubview(glyph)
            isAccessibilityElement = true
            accessibilityIdentifier = "chat.stickers"
            addTarget(self, action: #selector(activate), for: .touchUpInside)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override var intrinsicContentSize: CGSize { CGSize(width: 44, height: 44) }
        override func layoutSubviews() {
            super.layoutSubviews()
            // Keyboard movement belongs to the outer layout, not this layer.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            glyph.frame = CGRect(x: (bounds.width - 26) / 2, y: (bounds.height - 26) / 2, width: 26, height: 26)
            CATransaction.commit()
        }
        func configure(stickerMode: Bool, reduced: Bool) {
            let changed = mode != nil && mode != stickerMode
            mode = stickerMode
            self.reduced = reduced
            accessibilityLabel = stickerMode ? "切回键盘" : "表情包"
            accessibilityValue = stickerMode ? "sticker" : "keyboard"
            glyph.tintColor = UIColor(CoveStyle.secondaryText)
            let update = {
                self.glyph.image = stickerMode
                    ? UIImage(systemName: "keyboard", withConfiguration: UIImage.SymbolConfiguration(pointSize: 21, weight: .regular))
                    : Self.stickerImage
            }
            if changed && !reduced && window != nil {
                UIView.transition(with: glyph, duration: 0.16,
                                  options: [.transitionCrossDissolve, .beginFromCurrentState, .allowUserInteraction], animations: update)
            } else { update() }
        }
        override var isHighlighted: Bool {
            didSet {
                guard oldValue != isHighlighted else { return }
                if isHighlighted || reduced { glyph.alpha = isHighlighted ? 0.4 : 1 }
                else { UIView.animate(withDuration: 0.2) { self.glyph.alpha = 1 } }
            }
        }
        override func accessibilityActivate() -> Bool { action?(); return true }
        @objc private func activate() { action?() }

        // Independently drawn folded-corner sticker, rather than a generic
        // smile SF Symbol. It shares the lightweight outline of the keyboard.
        private static let stickerImage: UIImage = UIGraphicsImageRenderer(size: CGSize(width: 24, height: 24)).image { _ in
            UIColor.black.setStroke()
            UIColor.black.setFill()
            let outline = UIBezierPath()
            outline.move(to: CGPoint(x: 8, y: 2.5))
            outline.addLine(to: CGPoint(x: 16, y: 2.5))
            outline.addQuadCurve(to: CGPoint(x: 21.5, y: 8), controlPoint: CGPoint(x: 21.5, y: 2.5))
            outline.addLine(to: CGPoint(x: 21.5, y: 15))
            outline.addLine(to: CGPoint(x: 15, y: 21.5))
            outline.addLine(to: CGPoint(x: 8, y: 21.5))
            outline.addQuadCurve(to: CGPoint(x: 2.5, y: 16), controlPoint: CGPoint(x: 2.5, y: 21.5))
            outline.addLine(to: CGPoint(x: 2.5, y: 8))
            outline.addQuadCurve(to: CGPoint(x: 8, y: 2.5), controlPoint: CGPoint(x: 2.5, y: 2.5))
            outline.close()
            outline.lineWidth = 1.7
            outline.lineJoinStyle = .round
            outline.stroke()
            let fold = UIBezierPath()
            fold.move(to: CGPoint(x: 15, y: 21.5))
            fold.addLine(to: CGPoint(x: 15, y: 18))
            fold.addQuadCurve(to: CGPoint(x: 18, y: 15), controlPoint: CGPoint(x: 15, y: 15))
            fold.addLine(to: CGPoint(x: 21.5, y: 15))
            fold.lineWidth = 1.7
            fold.stroke()
            for x in [8.0, 14.0] { UIBezierPath(ovalIn: CGRect(x: x, y: 8, width: 1.8, height: 2.3)).fill() }
            let smile = UIBezierPath()
            smile.move(to: CGPoint(x: 7.8, y: 13))
            smile.addQuadCurve(to: CGPoint(x: 13.8, y: 14), controlPoint: CGPoint(x: 10, y: 16))
            smile.lineWidth = 1.5
            smile.lineCapStyle = .round
            smile.stroke()
        }.withRenderingMode(.alwaysTemplate)
    }
}

private extension UIView {
    var nearestViewController: UIViewController? {
        var responder: UIResponder? = self
        while let current = responder {
            if let controller = current as? UIViewController { return controller }
            responder = current.next
        }
        return nil
    }
}
