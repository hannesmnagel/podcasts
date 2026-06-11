import UIKit
import WebKit

enum ShowNotesText {
    private static let collapsedMaxLines = 6
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
        let blocks = ShowNotesBlockParser.parse(raw)
        guard !blocks.isEmpty else {
            return blockLabel("No show notes.", font: .preferredFont(forTextStyle: .body), color: secondaryColor)
        }
        let web = AutoSizingTextWebView()
        web.loadHTMLString(makeHTML(blocks: blocks, textColor: textColor, secondaryColor: secondaryColor, linkColor: .systemOrange), baseURL: nil)
        return web
    }

    @MainActor
    static func collapsibleView(raw: String, textColor: UIColor = .label, secondaryColor: UIColor = .secondaryLabel, onExpansionChange: (() -> Void)? = nil) -> UIView {
        let text = ShowNotesProcessor.plainText(raw)
        guard !text.isEmpty else {
            return blockLabel("No show notes.", font: .preferredFont(forTextStyle: .body), color: secondaryColor)
        }
        return CollapsibleLinkedTextView(
            raw: raw,
            font: .preferredFont(forTextStyle: .body),
            textColor: textColor,
            secondaryColor: secondaryColor,
            maxCollapsedLines: collapsedMaxLines,
            onExpansionChange: onExpansionChange
        )
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

private extension ShowNotesText {
    static func makeHTML(blocks: [ShowNotesBlock], textColor: UIColor, secondaryColor: UIColor, linkColor: UIColor) -> String {
        let rgba = cssRGBA(textColor)
        let secondary = cssRGBA(secondaryColor)
        let linkRGBA = cssRGBA(linkColor)
        let body = blocks.map { block -> String in
            switch block.kind {
            case .heading(let text):
                return "<h3>\(linkify(escapeHTML(text)))</h3>"
            case .paragraph(let text):
                return "<p>\(linkify(escapeHTML(text)))</p>"
            case .bulletList(let items):
                let listItems = items.map { "<li>\(linkify(escapeHTML($0)))</li>" }.joined()
                return "<ul>\(listItems)</ul>"
            }
        }.joined(separator: "\n")
        return """
        <!doctype html>
        <html>
        <head>
          <meta name="viewport" content="width=device-width, initial-scale=1.0, viewport-fit=cover">
          <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline';">
          <style>
            body {
              margin: 0;
              font: -apple-system-body;
              color: \(rgba);
              line-height: 1.45;
              white-space: normal;
              -webkit-user-select: text;
              user-select: text;
              word-break: break-word;
            }
            h3 { margin: 0 0 8px; font: -apple-system-headline; color: \(rgba); }
            p { margin: 0 0 10px; }
            ul { margin: 0 0 12px 20px; padding: 0; }
            li { margin: 0 0 8px; color: \(secondary); }
            li > a, li { color: \(secondary); }
            a { color: \(linkRGBA); text-decoration: none; }
            a:hover { text-decoration: underline; }
          </style>
        </head>
        <body>\(body)</body>
        </html>
        """
    }

    static func cssRGBA(_ color: UIColor) -> String {
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        return "rgba(\(Int(r * 255)), \(Int(g * 255)), \(Int(b * 255)), \(a))"
    }

    static func escapeHTML(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    static func linkify(_ htmlEscapedText: String) -> String {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return htmlEscapedText
        }
        let source = htmlEscapedText
        let ns = source as NSString
        let range = NSRange(location: 0, length: ns.length)
        var output = ""
        var cursor = 0
        for match in detector.matches(in: source, options: [], range: range) {
            guard let url = match.url else { continue }
            let matchRange = match.range
            if matchRange.location > cursor {
                output += ns.substring(with: NSRange(location: cursor, length: matchRange.location - cursor))
            }
            let text = ns.substring(with: matchRange)
            output += "<a href=\"\(url.absoluteString)\">\(text)</a>"
            cursor = matchRange.location + matchRange.length
        }
        if cursor < ns.length {
            output += ns.substring(from: cursor)
        }
        return output
    }
}

private final class AutoSizingTextWebView: UIView, WKNavigationDelegate, UIScrollViewDelegate {
    private let webView: WKWebView
    private var heightConstraint: NSLayoutConstraint?

    override init(frame: CGRect) {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        webView = WKWebView(frame: .zero, configuration: config)
        super.init(frame: frame)

        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        webView.navigationDelegate = self
        webView.scrollView.delegate = self
        addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        let h = heightAnchor.constraint(equalToConstant: 1)
        h.priority = .defaultHigh
        h.isActive = true
        heightConstraint = h
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func loadHTMLString(_ html: String, baseURL: URL?) {
        webView.loadHTMLString(html, baseURL: baseURL)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        refreshHeight()
    }

    @MainActor
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        let allowedSchemes = Set(["about", "data"])
        if navigationAction.navigationType == .linkActivated,
           let scheme = url.scheme,
           ["http", "https"].contains(scheme) {
            UIApplication.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        if let scheme = url.scheme, allowedSchemes.contains(scheme) {
            decisionHandler(.allow)
            return
        }
        decisionHandler(.cancel)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        refreshHeight()
    }

    private func refreshHeight() {
        webView.evaluateJavaScript("document.documentElement.scrollHeight") { [weak self] value, _ in
            guard let self, let height = value as? CGFloat else { return }
            self.heightConstraint?.constant = max(1, ceil(height))
            self.invalidateIntrinsicContentSize()
            self.superview?.setNeedsLayout()
        }
    }
}

private final class CollapsibleLinkedTextView: UIView {
    private let textView = UITextView()
    private let showMoreButton = UIButton(type: .system)
    private let maxCollapsedLines: Int
    private let onExpansionChange: (() -> Void)?

    init(raw: String, font: UIFont, textColor: UIColor, secondaryColor: UIColor, maxCollapsedLines: Int, onExpansionChange: (() -> Void)?) {
        self.maxCollapsedLines = maxCollapsedLines
        self.onExpansionChange = onExpansionChange
        super.init(frame: .zero)

        var linked = ShowNotesProcessor.linkedText(raw)
        linked.font = font
        linked.foregroundColor = textColor
        let attributed = NSAttributedString(linked)

        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.backgroundColor = .clear
        textView.isEditable = false
        textView.isScrollEnabled = false
        textView.isSelectable = true
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.adjustsFontForContentSizeCategory = true
        textView.attributedText = attributed
        textView.linkTextAttributes = [.foregroundColor: UIColor.systemOrange]
        textView.textContainer.maximumNumberOfLines = maxCollapsedLines
        textView.textContainer.lineBreakMode = .byTruncatingTail

        var config = UIButton.Configuration.plain()
        config.title = "Show more"
        config.image = UIImage(systemName: "chevron.down", withConfiguration: UIImage.SymbolConfiguration(scale: .small))
        config.imagePlacement = .trailing
        config.imagePadding = 4
        config.baseForegroundColor = .systemOrange
        config.contentInsets = .zero
        showMoreButton.configuration = config
        showMoreButton.translatesAutoresizingMaskIntoConstraints = false
        showMoreButton.addAction(UIAction { [weak self] _ in self?.expand() }, for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [textView, showMoreButton])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        let width: CGFloat = 320
        let lineHeight = font.lineHeight
        let collapsedHeight = CGFloat(maxCollapsedLines) * lineHeight
        let fullHeight = textView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        if fullHeight <= collapsedHeight + 4 {
            textView.textContainer.maximumNumberOfLines = 0
            showMoreButton.isHidden = true
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func expand() {
        textView.textContainer.maximumNumberOfLines = 0
        textView.invalidateIntrinsicContentSize()
        textView.setNeedsLayout()
        showMoreButton.isHidden = true
        invalidateIntrinsicContentSize()
        // Walk up the hierarchy to find a scroll view and trigger a full relayout
        var view: UIView? = superview
        while let v = view {
            v.setNeedsLayout()
            if v is UIScrollView { break }
            view = v.superview
        }
        superview?.layoutIfNeeded()
        onExpansionChange?()
    }
}
