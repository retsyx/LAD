import AppKit

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
