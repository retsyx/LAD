import AppKit
import Observation

/// A design window's conversation search, shared by its header toggle, search
/// bar and Find menu commands. It is transient and never saved with the design.
@MainActor @Observable
final class ConversationSearchController {
    struct Step: Equatable {
        let id = UUID()
        let forward: Bool
    }

    private(set) var isVisible = false
    var query = ""
    var index = 0
    /// Matches in the window's current conversation, reported by its view.
    var matchCount = 0
    /// Requests the window's conversation handles once each.
    private(set) var focusRequest = 0
    private(set) var stepRequest: Step?

    var isActive: Bool { isVisible && ConversationSearch.isActive(query) }
    var canStep: Bool { isActive && matchCount > 0 }

    /// Shows the search bar and focuses its field.
    func show() {
        isVisible = true
        focusRequest &+= 1
    }

    /// Hiding ends the search, removing its highlights.
    func hide() {
        isVisible = false
        query = ""
        index = 0
        stepRequest = nil
    }

    func toggle() { isVisible ? hide() : show() }

    func step(forward: Bool) {
        guard canStep else { return }
        stepRequest = Step(forward: forward)
    }
}

/// One occurrence of the search text in a conversation message.
struct ConversationSearchMatch: Equatable {
    let messageID: UUID
    let range: Range<String.Index>
}

/// Finds text in a design conversation. Search is a transient per-window view
/// state; it never changes or saves the design.
enum ConversationSearch {
    private static let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

    /// Whitespace alone would highlight every gap between words.
    static func isActive(_ query: String) -> Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Non-overlapping matches of message text in conversation order.
    static func matches(in messages: [ChatMessage], for query: String) -> [ConversationSearchMatch] {
        guard isActive(query) else { return [] }
        var matches: [ConversationSearchMatch] = []
        for message in messages {
            let content = message.content
            var start = content.startIndex
            while start < content.endIndex,
                  let range = content.range(of: query, options: options, range: start..<content.endIndex),
                  !range.isEmpty {
                matches.append(ConversationSearchMatch(messageID: message.id, range: range))
                start = range.upperBound
            }
        }
        return matches
    }

    /// The adjacent match, wrapping at either end of the conversation.
    static func step(from index: Int, count: Int, forward: Bool) -> Int {
        guard count > 0 else { return 0 }
        return ((index + (forward ? 1 : -1)) % count + count) % count
    }

    /// The vertical center of the match's wrapped line as a fraction of the
    /// text's height, so scrolling can reveal matches inside long messages.
    static func verticalFraction(of range: Range<String.Index>, in content: String, width: CGFloat,
                                 font: NSFont, lineSpacing: CGFloat) -> CGFloat {
        guard width > 0, !content.isEmpty else { return 0 }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        let storage = NSTextStorage(string: content, attributes: [.font: font, .paragraphStyle: paragraph])
        let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        let layout = NSLayoutManager()
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        layout.ensureLayout(for: container)
        let height = layout.usedRect(for: container).height
        let glyphs = layout.glyphRange(forCharacterRange: NSRange(range, in: content), actualCharacterRange: nil)
        guard height > 0, glyphs.location < layout.numberOfGlyphs else { return 0 }
        let line = layout.lineFragmentUsedRect(forGlyphAt: glyphs.location, effectiveRange: nil)
        return min(max(line.midY / height, 0), 1)
    }
}
