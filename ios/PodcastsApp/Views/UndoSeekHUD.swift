import UIKit

@MainActor
final class UndoSeekHUD {
    static let shared = UndoSeekHUD()

    private var hostView: UIView?
    private var stackView: UIStackView?
    private var toastViews: [SeekUndoAction.ID: UIVisualEffectView] = [:]
    private var hideTasks: [SeekUndoAction.ID: Task<Void, Never>] = [:]

    private init() {}

    func show(action: SeekUndoAction) {
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
            try? await Task.sleep(for: .seconds(2))
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
        hud.isUserInteractionEnabled = false

        let label = UILabel()
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .label
        label.numberOfLines = 1
        label.text = detailText(for: action)

        label.translatesAutoresizingMaskIntoConstraints = false
        hud.contentView.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: hud.contentView.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: hud.contentView.trailingAnchor, constant: -16),
            label.topAnchor.constraint(equalTo: hud.contentView.topAnchor, constant: 12),
            label.bottomAnchor.constraint(equalTo: hud.contentView.bottomAnchor, constant: -12)
        ])
        return hud
    }

    private func hide(actionID: SeekUndoAction.ID?) {
        guard let actionID else { return }
        hideTasks[actionID]?.cancel()
        hideTasks[actionID] = nil
        guard let toast = toastViews[actionID] else { return }
        UIView.animate(withDuration: 0.18, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState], animations: {
            toast.alpha = 0
            toast.transform = CGAffineTransform(translationX: 0, y: 12)
        }, completion: { _ in
            toast.removeFromSuperview()
        })
        toastViews[actionID] = nil
        if toastViews.isEmpty {
            hostView?.removeFromSuperview()
            hostView = nil
            stackView = nil
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
