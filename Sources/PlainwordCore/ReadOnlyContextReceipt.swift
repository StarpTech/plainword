import Foundation

/// One line of the account Plainword can give of what it is sending with a request.
public struct ReadOnlyContextReceiptItem: Equatable, Sendable, Identifiable {
    /// What sort of thing this line describes, so a view can pick an icon without
    /// knowing anything about the Accessibility API.
    public enum Category: String, Equatable, Sendable {
        case application
        case field
        case document
        case nearbyText
        case surroundingText
    }

    public let id: Int
    public let category: Category
    /// A few words naming the source, e.g. "Text above".
    public let title: String
    /// The content itself, flattened to one line so it can sit in a row.
    ///
    /// It is not shortened: a row truncates it to fit, and hovering shows the whole
    /// thing. Cutting it here would mean the account could not be inspected in full,
    /// which is the one thing it exists to allow.
    public let detail: String

    public init(id: Int, category: Category, title: String, detail: String) {
        self.id = id
        self.category = category
        self.title = title
        self.detail = detail
    }
}

/// Turns the context attached to a request into something a person can read.
///
/// Plainword reads text from the interface the author is writing in, which is only
/// reasonable if the author can see exactly what that came to. Rather than describing
/// the policy, this itemises the actual payload: one line per piece, in the order the
/// model receives them.
public enum ReadOnlyContextReceipt {
    public static func items(for context: TextEditContext) -> [ReadOnlyContextReceiptItem] {
        var items = context.applicationContextFragments.compactMap {
            fragment -> (ReadOnlyContextReceiptItem.Category, String, String)? in
            guard let detail = singleLine(fragment.text) else { return nil }
            let description = description(for: fragment.kind)
            return (description.category, description.title, detail)
        }

        // The sentences on either side of the target travel with every request and are
        // the least obvious part of the payload, because they are not "context the app
        // exposed" — they are the author's own writing, just outside the edit.
        if let surrounding = surroundingDetail(
            leading: context.leadingContext,
            trailing: context.trailingContext
        ) {
            items.append((.surroundingText, "Around your text", surrounding))
        }

        return items.enumerated().map { index, item in
            ReadOnlyContextReceiptItem(
                id: index,
                category: item.0,
                title: item.1,
                detail: item.2
            )
        }
    }

    /// Wording for the collapsed control, which has room for a tooltip and nothing else.
    ///
    /// It carries both halves — how much was found, and whether any of it left the
    /// machine — because that is the whole question someone hovering is asking. The
    /// second half describes the suggestion on screen, which is what the list is about.
    public static func summary(forItemCount count: Int, wasAttached: Bool) -> String {
        guard count > 0 else { return "Nothing found nearby" }
        let found = count == 1 ? "1 thing found nearby" : "\(count) things found nearby"
        return wasAttached ? "\(found) — attached" : "\(found) — not attached"
    }

    private static func description(
        for kind: ReadOnlyContextKind
    ) -> (category: ReadOnlyContextReceiptItem.Category, title: String) {
        switch kind {
        case .sourceApplication: (.application, "App")
        case .fieldLabel: (.field, "Field label")
        case .fieldIdentity: (.field, "Field name")
        case .fieldPlaceholder: (.field, "Placeholder")
        case .fieldDescription: (.field, "Field hint")
        case .fieldHelp: (.field, "Field help")
        case .documentTitle: (.document, "Title")
        case .relatedPrecedingContent: (.nearbyText, "Text above")
        case .relatedContent: (.nearbyText, "Nearby text")
        }
    }

    private static func surroundingDetail(
        leading: String,
        trailing: String
    ) -> String? {
        let parts = [leading, trailing].compactMap(singleLine)
        guard !parts.isEmpty else { return nil }
        return singleLine(parts.joined(separator: " … "))
    }

    private static func singleLine(_ text: String) -> String? {
        let collapsed = text
            .replacingOccurrences(of: "\u{00a0}", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return collapsed.isEmpty ? nil : collapsed
    }
}
