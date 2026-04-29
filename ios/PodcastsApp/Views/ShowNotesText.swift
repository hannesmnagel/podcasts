import UIKit

enum ShowNotesText {
    @MainActor
    static func label(html: String, font: UIFont = .preferredFont(forTextStyle: .body)) -> UILabel {
        let label = UILabel()
        label.font = font
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0
        label.text = ShowNotesProcessor.plainText(html)
        return label
    }

    @MainActor
    static func view(raw: String, textColor: UIColor = .label, secondaryColor: UIColor = .secondaryLabel) -> UIView {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 10

        let blocks = ShowNotesBlockParser.parse(raw)
        if blocks.isEmpty {
            stack.addArrangedSubview(blockLabel("No show notes.", font: .preferredFont(forTextStyle: .body), color: secondaryColor))
            return stack
        }

        for block in blocks {
            switch block.kind {
            case .heading(let text):
                stack.addArrangedSubview(blockLabel(text, font: .preferredFont(forTextStyle: .headline), color: textColor))
            case .paragraph(let text):
                stack.addArrangedSubview(textView(text: text, font: .preferredFont(forTextStyle: .body), color: textColor))
            case .bulletList(let items):
                let bulletStack = UIStackView()
                bulletStack.axis = .vertical
                bulletStack.spacing = 7
                for item in items {
                    let bullet = blockLabel("•", font: .preferredFont(forTextStyle: .body), color: secondaryColor)
                    bullet.setContentHuggingPriority(.required, for: .horizontal)
                    let rowText = textView(text: item, font: .preferredFont(forTextStyle: .body), color: textColor)
                    let row = UIStackView(arrangedSubviews: [bullet, rowText])
                    row.axis = .horizontal
                    row.alignment = .firstBaseline
                    row.spacing = 8
                    bulletStack.addArrangedSubview(row)
                }
                stack.addArrangedSubview(bulletStack)
            }
        }

        return stack
    }

    @MainActor
    private static func blockLabel(_ text: String, font: UIFont, color: UIColor) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = font
        label.textColor = color
        label.numberOfLines = 0
        label.adjustsFontForContentSizeCategory = true
        return label
    }

    @MainActor
    private static func textView(text: String, font: UIFont, color: UIColor) -> UITextView {
        let textView = UITextView()
        textView.backgroundColor = .clear
        textView.isEditable = false
        textView.isScrollEnabled = false
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.dataDetectorTypes = [.link]
        textView.adjustsFontForContentSizeCategory = true
        textView.attributedText = attributedText(text, font: font, color: color)
        textView.linkTextAttributes = [
            .foregroundColor: UIColor.systemOrange
        ]
        return textView
    }

    private static func attributedText(_ text: String, font: UIFont, color: UIColor) -> NSAttributedString {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 3
        paragraphStyle.paragraphSpacing = 8

        let attributed = NSMutableAttributedString(
            string: text,
            attributes: [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: paragraphStyle
            ]
        )

        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return attributed
        }

        let range = NSRange(location: 0, length: attributed.length)
        for match in detector.matches(in: text, range: range) {
            guard let url = match.url else { continue }
            attributed.addAttribute(.link, value: url, range: match.range)
        }
        return attributed
    }
}
