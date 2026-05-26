import UIKit

@MainActor
final class UndoSeekHUD {
    static let shared = UndoSeekHUD()

    private var hostView: UIView?
    private var stackView: UIStackView?
    private var toastViews: [SeekUndoAction.ID: UIVisualEffectView] = [:]
    private var hideTasks: [SeekUndoAction.ID: Task<Void, Never>] = [:]
    private var undoHandler: ((SeekUndoAction) -> Void)?
    private var dismissHandler: ((SeekUndoAction) -> Void)?
    private var actionsByID: [SeekUndoAction.ID: SeekUndoAction] = [:]

    private init() {}

    func show(action: SeekUndoAction, undo: @escaping (SeekUndoAction) -> Void, dismiss: @escaping (SeekUndoAction) -> Void) {
        undoHandler = undo
        dismissHandler = dismiss
        actionsByID[action.id] = action
        installIfNeeded()

        let toast = makeToast(for: action)
        toast.transform = CGAffineTransform(translationX: 0, y: 12)
        toast.alpha = 0
        stackView?.insertArrangedSubview(toast, at: 0)
        toastViews[action.id] = toast

        UIView.animate(withDuration: 0.18, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
            toast.alpha = 1
            toast.transform = .identity
        }

        hideTasks[action.id]?.cancel()
        hideTasks[action.id] = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard self.actionsByID[action.id] != nil else { return }
            dismiss(action)
            self.hide(actionID: action.id)
        }
    }

    private func installIfNeeded() {
        guard hostView == nil, let window = Self.keyWindow else { return }

        let host = UIView()
        host.translatesAutoresizingMaskIntoConstraints = false
        host.isUserInteractionEnabled = false

        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 8
        stack.alignment = .fill
        stack.distribution = .fill
        host.addSubview(stack)
        window.addSubview(host)

        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(greaterThanOrEqualTo: window.safeAreaLayoutGuide.leadingAnchor, constant: 18),
            host.trailingAnchor.constraint(lessThanOrEqualTo: window.safeAreaLayoutGuide.trailingAnchor, constant: -18),
            host.centerXAnchor.constraint(equalTo: window.safeAreaLayoutGuide.centerXAnchor),
            host.bottomAnchor.constraint(equalTo: window.safeAreaLayoutGuide.bottomAnchor, constant: -18),
            host.widthAnchor.constraint(lessThanOrEqualToConstant: 520),
            stack.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            stack.topAnchor.constraint(equalTo: host.topAnchor),
            stack.bottomAnchor.constraint(equalTo: host.bottomAnchor)
        ])

        hostView = host
        stackView = stack
    }

    private func makeToast(for action: SeekUndoAction) -> UIVisualEffectView {
        let hud = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
        hud.translatesAutoresizingMaskIntoConstraints = false
        hud.layer.cornerRadius = 18
        hud.layer.cornerCurve = .continuous
        hud.clipsToBounds = true
        hud.isUserInteractionEnabled = true

        let label = UILabel()
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .label
        label.numberOfLines = 1
        label.text = detailText(for: action)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        var configuration = UIButton.Configuration.filled()
        configuration.cornerStyle = .capsule
        configuration.baseBackgroundColor = .systemOrange
        configuration.baseForegroundColor = .white
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 7, leading: 16, bottom: 7, trailing: 16)
        let button = UIButton(type: .system)
        button.configuration = configuration
        button.addAction(UIAction { [weak self] _ in
            self?.undoTapped(actionID: action.id)
        }, for: .touchUpInside)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.accessibilityLabel = "Undo Seek"
        button.setTitle("Undo", for: .normal)

        let stack = UIStackView(arrangedSubviews: [label, button])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 14
        hud.contentView.addSubview(stack)
        window.addSubview(hud)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: hud.contentView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: hud.contentView.trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: hud.contentView.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: hud.contentView.bottomAnchor, constant: -10)
        ])
        return hud
    }

    private func undoTapped(actionID: SeekUndoAction.ID) {
        guard let action = actionsByID[actionID] else { return }
        undoHandler?(action)
        hide(actionID: action.id)
    }

    private func hide(actionID: SeekUndoAction.ID?) {
        guard let actionID else { return }
        hideTasks[actionID]?.cancel()
        hideTasks[actionID] = nil
        actionsByID[actionID] = nil
        guard let toast = toastViews[actionID] else { return }
        UIView.animate(withDuration: 0.18, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState], animations: {
            toast.alpha = 0
            toast.transform = CGAffineTransform(translationX: 0, y: 12)
        }, completion: { _ in
            toast.removeFromSuperview()
        })
        toastViews[actionID] = nil
        if actionsByID.isEmpty {
            undoHandler = nil
            dismissHandler = nil
        }
    }

    private func detailText(for action: SeekUndoAction) -> String {
        let delta = action.to - action.from
        let prefix = delta >= 0 ? "Skipped forward" : "Skipped back"
        return "\(prefix) \(TimeFormatting.playbackTime(abs(delta)))"
    }

    private static var keyWindow: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
    }
}
