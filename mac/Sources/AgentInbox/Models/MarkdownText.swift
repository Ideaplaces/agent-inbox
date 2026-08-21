import Foundation

/// Agents write markdown, so their words arrive with `**` and backticks in
/// them. Two surfaces need two different answers.
///
/// The menu can show formatting, so it renders. A notification banner is plain
/// text and cannot, so it strips the markers rather than showing them raw,
/// which is what `**like this**` was doing.
enum MarkdownText {
    /// Inline only, and whitespace preserving. Full markdown would try to
    /// restructure a snippet into blocks, turning a line that merely starts
    /// with "-" into a list and a line starting with "#" into a heading.
    private static let options = AttributedString.MarkdownParsingOptions(
        allowsExtendedAttributes: false,
        interpretedSyntax: .inlineOnlyPreservingWhitespace,
        failurePolicy: .returnPartiallyParsedIfPossible)

    /// For the menu, where bold and code can actually be drawn.
    static func attributed(_ raw: String) -> AttributedString {
        (try? AttributedString(markdown: raw, options: options)) ?? AttributedString(raw)
    }

    /// For anywhere that is plain text: same parse, markers dropped.
    static func plain(_ raw: String) -> String {
        String(attributed(raw).characters)
    }
}
