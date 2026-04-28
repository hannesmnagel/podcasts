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
}
