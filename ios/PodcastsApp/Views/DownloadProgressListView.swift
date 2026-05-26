import Combine
import UIKit

@MainActor
final class FloatingDownloadHUD {
    static let shared = FloatingDownloadHUD()

    private var container: UIVisualEffectView?
    private var titleLabel: UILabel?
    private var detailLabel: UILabel?
    private var progressView: UIProgressView?
    private var cancellable: AnyCancellable?
    private var currentProgressID: String?

    private init() {}

    func show(progressID: String, title: String?) {
        currentProgressID = progressID
        installIfNeeded()
        titleLabel?.text = title?.isEmpty == false ? title : "Preparing episode"
        detailLabel?.text = "Preparing download..."
        progressView?.setProgress(0, animated: false)
        container?.alpha = 0
        UIView.animate(withDuration: 0.18) {
            self.container?.alpha = 1
        }

        cancellable = DownloadProgressCenter.shared.$progresses
            .receive(on: DispatchQueue.main)
            .sink { [weak self] progresses in
                self?.update(progresses[progressID])
            }

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard self.currentProgressID == progressID,
                  DownloadProgressCenter.shared.progresses[progressID] == nil else {
                return
            }
            self.hide()
        }
    }

    func showFailure(progressID: String, title: String?) {
        currentProgressID = progressID
        installIfNeeded()
        titleLabel?.text = title?.isEmpty == false ? title : "Episode download"
        detailLabel?.text = "Download failed"
        progressView?.setProgress(0, animated: false)
        container?.alpha = 0
        UIView.animate(withDuration: 0.18) {
            self.container?.alpha = 1
        }
        cancellable = nil
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.2))
            guard self.currentProgressID == progressID else { return }
            self.hide()
        }
    }

    private func installIfNeeded() {
        guard container == nil, let window = Self.keyWindow else { return }

        let blur = UIBlurEffect(style: .systemMaterial)
        let hud = UIVisualEffectView(effect: blur)
        hud.translatesAutoresizingMaskIntoConstraints = false
        hud.layer.cornerRadius = 18
        hud.layer.cornerCurve = .continuous
        hud.clipsToBounds = true

        let title = UILabel()
        title.font = .preferredFont(forTextStyle: .headline)
        title.adjustsFontForContentSizeCategory = true
        title.numberOfLines = 2

        let detail = UILabel()
        detail.font = .preferredFont(forTextStyle: .footnote)
        detail.adjustsFontForContentSizeCategory = true
        detail.textColor = .secondaryLabel

        let progress = UIProgressView(progressViewStyle: .default)
        progress.tintColor = .systemOrange

        let stack = UIStackView(arrangedSubviews: [title, detail, progress])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 8
        hud.contentView.addSubview(stack)
        window.addSubview(hud)

        NSLayoutConstraint.activate([
            hud.leadingAnchor.constraint(equalTo: window.safeAreaLayoutGuide.leadingAnchor, constant: 18),
            hud.trailingAnchor.constraint(equalTo: window.safeAreaLayoutGuide.trailingAnchor, constant: -18),
            hud.bottomAnchor.constraint(equalTo: window.safeAreaLayoutGuide.bottomAnchor, constant: -18),
            stack.leadingAnchor.constraint(equalTo: hud.contentView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: hud.contentView.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: hud.contentView.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: hud.contentView.bottomAnchor, constant: -14)
        ])

        container = hud
        titleLabel = title
        detailLabel = detail
        progressView = progress
    }

    private func update(_ progress: DownloadProgress?) {
        guard let progress else { return }
        titleLabel?.text = progress.title ?? "Episode download"
        detailLabel?.text = progress.isFinished ? "Download complete" : "Downloading \(progress.percentText)"
        progressView?.setProgress(Float(progress.fractionCompleted), animated: true)
        if progress.isFinished {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.2))
                self.hide()
            }
        }
    }

    private func hide() {
        currentProgressID = nil
        cancellable = nil
        guard let container else { return }
        UIView.animate(withDuration: 0.18, animations: {
            container.alpha = 0
        }, completion: { _ in
            container.removeFromSuperview()
        })
        self.container = nil
        titleLabel = nil
        detailLabel = nil
        progressView = nil
    }

    private static var keyWindow: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
    }
}

final class DownloadProgressListViewController: UITableViewController {
    private var progresses: [DownloadProgress] = []
    private var cancellable: AnyCancellable?

    init() {
        super.init(style: .insetGrouped)
        title = "Downloads"
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })
        tableView.register(DownloadProgressCell.self, forCellReuseIdentifier: DownloadProgressCell.reuseIdentifier)
        cancellable = DownloadProgressCenter.shared.$progresses
            .receive(on: DispatchQueue.main)
            .sink { [weak self] values in
                self?.progresses = values.values.sorted { lhs, rhs in
                    if lhs.isFinished != rhs.isFinished { return !lhs.isFinished }
                    return (lhs.title ?? lhs.id).localizedCaseInsensitiveCompare(rhs.title ?? rhs.id) == .orderedAscending
                }
                self?.tableView.reloadData()
            }
    }

    override func numberOfSections(in tableView: UITableView) -> Int { 1 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        max(1, progresses.count)
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if progresses.isEmpty {
            let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
            cell.textLabel?.text = "No downloads right now"
            cell.detailTextLabel?.text = "Active episode downloads will appear here."
            cell.selectionStyle = .none
            return cell
        }

        let cell = tableView.dequeueReusableCell(withIdentifier: DownloadProgressCell.reuseIdentifier, for: indexPath) as! DownloadProgressCell
        cell.configure(progresses[indexPath.row])
        return cell
    }
}

private final class DownloadProgressCell: UITableViewCell {
    static let reuseIdentifier = "DownloadProgressCell"

    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let progressView = UIProgressView(progressViewStyle: .default)

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none

        titleLabel.font = .preferredFont(forTextStyle: .body)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.numberOfLines = 2

        detailLabel.font = .preferredFont(forTextStyle: .footnote)
        detailLabel.adjustsFontForContentSizeCategory = true
        detailLabel.textColor = .secondaryLabel

        progressView.tintColor = .systemOrange

        let stack = UIStackView(arrangedSubviews: [titleLabel, detailLabel, progressView])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 8
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(_ progress: DownloadProgress) {
        titleLabel.text = progress.title ?? "Episode download"
        detailLabel.text = progress.isFinished ? "Download complete" : "Downloading \(progress.percentText)"
        progressView.progress = Float(progress.fractionCompleted)
    }
}
