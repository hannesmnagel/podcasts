import Combine
import UIKit

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
