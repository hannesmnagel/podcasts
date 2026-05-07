import UIKit

final class ChapterSkipRulesViewController: UITableViewController {
    private enum Section: Int, CaseIterable {
        case rules
        case help
    }

    private var rules: [ChapterSkipRule] = []

    init() {
        super.init(style: .insetGrouped)
        title = "Chapter Skips"
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "Cell")
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .add, primaryAction: UIAction { [weak self] _ in
            self?.showAddRuleOptions()
        })
        reloadRules()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reloadRules()
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        Section.allCases.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Section(rawValue: section) {
        case .rules:
            max(rules.count, 1)
        case .help:
            RegexHelpRow.allCases.count
        case nil:
            0
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch Section(rawValue: section) {
        case .rules:
            "Rules"
        case .help:
            "Regex Basics"
        case nil:
            nil
        }
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch Section(rawValue: section) {
        case .rules:
            "Exact title rules apply across episodes when chapter titles match. Regex rules are matched case-insensitively."
        case .help:
            "Tip: start with exact title rules. Use regex only when chapter titles vary in predictable ways."
        case nil:
            nil
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "Cell", for: indexPath)
        cell.accessoryView = nil
        cell.accessoryType = .none
        cell.selectionStyle = .default

        var configuration = UIListContentConfiguration.subtitleCell()
        configuration.textProperties.numberOfLines = 0
        configuration.secondaryTextProperties.numberOfLines = 0

        switch Section(rawValue: indexPath.section) {
        case .rules:
            if rules.isEmpty {
                configuration.text = "No chapter skip rules yet"
                configuration.secondaryText = "Tap + to add an exact title or regex rule."
                cell.selectionStyle = .none
            } else {
                let rule = rules[indexPath.row]
                configuration.text = rule.displayTitle
                configuration.secondaryText = rule.kind == .exactTitle ? "Exact chapter title" : "Regular expression"
                cell.accessoryType = .disclosureIndicator
            }
        case .help:
            let row = RegexHelpRow.allCases[indexPath.row]
            configuration.text = row.title
            configuration.secondaryText = row.detail
            cell.selectionStyle = .none
        case nil:
            break
        }

        cell.contentConfiguration = configuration
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard Section(rawValue: indexPath.section) == .rules, !rules.isEmpty else { return }
        showEditRule(rules[indexPath.row])
    }

    override func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard Section(rawValue: indexPath.section) == .rules, !rules.isEmpty else { return nil }
        let rule = rules[indexPath.row]
        let delete = UIContextualAction(style: .destructive, title: "Delete") { [weak self] _, _, completion in
            ChapterSkipRuleStore.remove(rule)
            self?.reloadRules()
            completion(true)
        }
        return UISwipeActionsConfiguration(actions: [delete])
    }

    private func reloadRules() {
        rules = ChapterSkipRuleStore.rules.sorted { $0.createdAt < $1.createdAt }
        tableView.reloadData()
    }

    private func showAddRuleOptions() {
        let alert = UIAlertController(title: "Add Chapter Skip", message: nil, preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: "Exact Chapter Title", style: .default) { [weak self] _ in
            self?.showRuleEditor(rule: nil, kind: .exactTitle)
        })
        alert.addAction(UIAlertAction(title: "Regex", style: .default) { [weak self] _ in
            self?.showRuleEditor(rule: nil, kind: .regex)
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
    }

    private func showEditRule(_ rule: ChapterSkipRule) {
        let alert = UIAlertController(title: rule.displayTitle, message: nil, preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: "Edit", style: .default) { [weak self] _ in
            self?.showRuleEditor(rule: rule, kind: rule.kind)
        })
        alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
            ChapterSkipRuleStore.remove(rule)
            self?.reloadRules()
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
    }

    private func showRuleEditor(rule: ChapterSkipRule?, kind: ChapterSkipRule.MatchKind) {
        let title = rule == nil ? "Add Rule" : "Edit Rule"
        let message = kind == .exactTitle ? "Enter the chapter title to skip exactly." : "Enter a regular expression to match chapter titles."
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addTextField { textField in
            textField.placeholder = kind == .exactTitle ? "Chapter title" : "e.g. ads?|sponsor"
            textField.text = rule?.pattern
            textField.autocapitalizationType = .none
            textField.autocorrectionType = .no
            textField.clearButtonMode = .whileEditing
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Save", style: .default) { [weak self, weak alert] _ in
            guard let self else { return }
            let pattern = alert?.textFields?.first?.text ?? ""
            let edited = ChapterSkipRule(
                id: rule?.id ?? UUID(),
                kind: kind,
                pattern: pattern,
                createdAt: rule?.createdAt ?? .now
            )
            guard ChapterSkipRuleStore.save(edited) else {
                self.showError(kind == .regex ? "That regular expression is invalid." : "Please enter a title.")
                return
            }
            self.reloadRules()
        })
        present(alert, animated: true)
    }

    private func showError(_ message: String) {
        let alert = UIAlertController(title: "Couldn’t Save Rule", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}

private enum RegexHelpRow: CaseIterable {
    case contains
    case alternatives
    case optional
    case wildcard
    case anchors
    case escaping

    var title: String {
        switch self {
        case .contains: "Contains text"
        case .alternatives: "Either/or"
        case .optional: "Optional letters"
        case .wildcard: "Any text"
        case .anchors: "Start or end"
        case .escaping: "Special characters"
        }
    }

    var detail: String {
        switch self {
        case .contains:
            "ads matches titles containing “ads”, like “Midroll Ads”. Matching is already case-insensitive."
        case .alternatives:
            "ad|sponsor matches either “ad” or “sponsor”. Use parentheses to group: (ad|sponsor) break."
        case .optional:
            "ads? matches “ad” or “ads” because ? makes the previous character optional."
        case .wildcard:
            ".* means any amount of text. Example: sponsor.*message matches “Sponsor Message”."
        case .anchors:
            "^intro matches only at the start. outro$ matches only at the end."
        case .escaping:
            "Characters like . ? * + ( ) are special. Add a backslash to match them literally, e.g. bonus\\.com."
        }
    }
}
