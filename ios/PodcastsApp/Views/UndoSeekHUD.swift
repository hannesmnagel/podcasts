import UIKit

@MainActor
final class UndoSeekHUD {
    static let shared = UndoSeekHUD()

    private var container: UIVisualEffectView?
    private var label: UILabel?
    private var undoButton: UIButton?
    private var currentActionID: SeekUndoAction.ID?
    private var hideTask: Task<Void, Never>?
    private var undoHandler: ((SeekUndoAction) -> Void)?
    private var dismissHandler: ((SeekUndoAction) -> Void)?
    private var action: SeekUndoAction?

    private init() {}

    func show(action: SeekUndoAction, undo: @escaping (SeekUndoAction) -> Void, dismiss: @escaping (SeekUndoAction) -> Void) {
        currentActionID = action.id
        self.action = action
        undoHandler = undo
        dismissHandler = dismiss
        installIfNeeded()

        label?.text = detailText(for: action)
        undoButton?.setTitle("Undo", for: .normal)
        container?.transform = CGAffineTransform(translationX: 0, y: 12)
        container?.alpha = 0

        UIView.animate(withDuration: 0.18, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
            self.container?.alpha = 1
            self.container?.transform = .identity
        }

        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard self.currentActionID == action.id else { return }
            dismiss(action)
            self.hide(actionID: action.id)
        }
    }

    private func installIfNeeded() {
        guard container == nil, let window = Self.keyWindow else { return }

        let hud = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
        hud.translatesAutoresizingMaskIntoConstraints = false
        hud.layer.cornerRadius = 18
        hud.layer.cornerCurve = .continuous
        hud.clipsToBounds = true

        let label = UILabel()
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .label
        label.numberOfLines = 1
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        var configuration = UIButton.Configuration.filled()
        configuration.cornerStyle = .capsule
        configuration.baseBackgroundColor = .systemOrange
        configuration.baseForegroundColor = .white
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 7, leading: 16, bottom: 7, trailing: 16)
        let button = UIButton(type: .system)
        button.configuration = configuration
        button.addTarget(self, action: #selector(undoTapped), for: .touchUpInside)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.accessibilityLabel = "Undo Seek"

        let stack = UIStackView(arrangedSubviews: [label, button])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 14
        hud.contentView.addSubview(stack)
        window.addSubview(hud)

        NSLayoutConstraint.activate([
            hud.leadingAnchor.constraint(greaterThanOrEqualTo: window.safeAreaLayoutGuide.leadingAnchor, constant: 18),
            hud.trailingAnchor.constraint(lessThanOrEqualTo: window.safeAreaLayoutGuide.trailingAnchor, constant: -18),
            hud.centerXAnchor.constraint(equalTo: window.safeAreaLayoutGuide.centerXAnchor),
            hud.bottomAnchor.constraint(equalTo: window.safeAreaLayoutGuide.bottomAnchor, constant: -18),
            stack.leadingAnchor.constraint(equalTo: hud.contentView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: hud.contentView.trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: hud.contentView.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: hud.contentView.bottomAnchor, constant: -10)
        ])

        container = hud
        self.label = label
        undoButton = button
    }

    @objc private func undoTapped() {
        guard let action else { return }
        undoHandler?(action)
        hide(actionID: action.id)
    }

    private func hide(actionID: SeekUndoAction.ID?) {
        guard currentActionID == actionID else { return }
        hideTask?.cancel()
        hideTask = nil
        currentActionID = nil
        action = nil
        undoHandler = nil
        dismissHandler = nil

        guard let container else { return }
        UIView.animate(withDuration: 0.18, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState], animations: {
            container.alpha = 0
            container.transform = CGAffineTransform(translationX: 0, y: 12)
        }, completion: { _ in
            container.removeFromSuperview()
        })
        self.container = nil
        label = nil
        undoButton = nil
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
