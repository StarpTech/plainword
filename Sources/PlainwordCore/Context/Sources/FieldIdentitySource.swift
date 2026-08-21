import Foundation

/// What the application says the focused field is.
///
/// Everything here is published by the application through a documented relationship, so
/// none of it is a guess: an `AXTitleUIElement` is that application naming its own field.
/// It is also the cheapest thing the pipeline can ask for, which is why it goes first.
public struct FieldIdentitySource: ContextSource {
    public static let sourceName = "field-identity"

    public let tier = ContextTier.identity
    public let name = FieldIdentitySource.sourceName

    public init() {}

    public func read(_ workspace: ContextWorkspace) -> [ReadOnlyContextCandidate] {
        let element = workspace.target.element
        let names = [
            AXName.title,
            AXName.placeholder,
            AXName.description,
            AXName.help,
            AXName.titleUIElement,
            AXName.linkedUIElements
        ]
        let values = workspace.attributes(names, of: element)
        var candidates: [ReadOnlyContextCandidate] = []
        let order = ReadOnlyContextGeometry.metadataReadingOrder

        func append(_ name: String, kind: ReadOnlyContextKind, relevance: Int) {
            // An application that publishes the attribute but leaves it empty is saying
            // nothing, and an empty fragment still costs a labelled block in the prompt.
            guard let text = values[name]?.stringValue,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return
            }
            candidates.append(
                .init(
                    kind: kind,
                    text: text,
                    relevance: relevance,
                    readingOrder: order,
                    provenance: provenance(.stated)
                )
            )
        }

        // AXTitle and AXDescription both carry the accessible name depending on the
        // framework, so neither can be claimed as the label rather than the description.
        append(AXName.title, kind: .fieldIdentity, relevance: 970)
        append(AXName.description, kind: .fieldIdentity, relevance: 950)
        append(AXName.placeholder, kind: .fieldPlaceholder, relevance: 820)
        append(AXName.help, kind: .fieldHelp, relevance: 310)

        if let labelElement = values[AXName.titleUIElement]?.elementValue,
           !workspace.facts(of: labelElement).isProtected,
           let text = workspace.readableText(of: labelElement) {
            candidates.append(
                .init(
                    kind: .fieldLabel,
                    text: text,
                    relevance: 1_100,
                    readingOrder: order,
                    provenance: provenance(.stated)
                )
            )
        }

        let linked = values[AXName.linkedUIElements]?.elementsValue ?? []
        for (index, linkedElement) in linked.prefix(3).enumerated() {
            guard !workspace.budget.isExhausted else { break }
            let facts = workspace.facts(of: linkedElement)
            guard let role = facts.role,
                  AXRole.readableContext.contains(role),
                  !facts.isExcludedFromContext,
                  !facts.isEditable,
                  !workspace.isWritableTextElement(linkedElement, role: role),
                  let text = workspace.readableText(of: linkedElement) else {
                continue
            }
            candidates.append(
                .init(
                    kind: .relatedContent,
                    text: text,
                    relevance: 520 - index * 10,
                    readingOrder: order + index,
                    provenance: provenance(.stated)
                )
            )
        }
        return candidates
    }
}

/// Which document the field belongs to.
///
/// A page address is one round trip and says more about what is being written than any
/// amount of nearby text: a compose view, a pull request, a ticket form and a wiki page
/// all want different assumptions, and the URL distinguishes them before anything has
/// been read.
public struct DocumentIdentitySource: ContextSource {
    public static let sourceName = "document-identity"

    public let tier = ContextTier.identity
    public let name = DocumentIdentitySource.sourceName

    public init() {}

    public func read(_ workspace: ContextWorkspace) -> [ReadOnlyContextCandidate] {
        var candidates: [ReadOnlyContextCandidate] = []
        // Ranked by how many documents were passed on the way out rather than by how
        // far the field sits from the window. A tab title answers "where is this text
        // going" just as well whether the composer is two nodes inside the page or
        // forty, and decaying it by node distance sank it below the relevance floor in
        // exactly the interfaces — web and Electron composers — where it is often the
        // only thing naming the destination at all.
        var documentDepth = 0
        for level in workspace.ancestry() where isDocumentRole(level.facts.role) {
            guard !workspace.budget.isExhausted else { break }
            let values = workspace.attributes(
                [AXName.title, AXName.url, AXName.document],
                of: level.element
            )
            let order = ReadOnlyContextGeometry.metadataReadingOrder + documentDepth
            if let title = values[AXName.title]?.stringValue {
                candidates.append(
                    .init(
                        kind: .documentTitle,
                        text: title,
                        relevance: 850 - documentDepth * 20,
                        readingOrder: order,
                        provenance: provenance(.stated)
                    )
                )
            }
            let address = values[AXName.url]?.stringValue
                ?? values[AXName.document]?.stringValue
            if let address, let readable = Self.readableAddress(address) {
                candidates.append(
                    .init(
                        kind: .documentTitle,
                        text: readable,
                        relevance: 840 - documentDepth * 20,
                        readingOrder: order,
                        provenance: provenance(.stated)
                    )
                )
            }
            documentDepth += 1
        }
        return candidates
    }

    private func isDocumentRole(_ role: String?) -> Bool {
        guard let role else { return false }
        return role == AXRole.window || role == AXRole.webArea || role == AXRole.document
    }

    /// Keeps the part of an address that says where the author is, and drops the part
    /// that only says how they got there.
    ///
    /// Query strings and fragments carry session tokens, search terms, and identifiers
    /// that are nobody's business in a writing prompt; the host and path are what tell
    /// the model this is a review comment rather than a wiki page.
    static func readableAddress(_ address: String) -> String? {
        guard let components = URLComponents(string: address),
              let host = components.host,
              let scheme = components.scheme,
              scheme == "https" || scheme == "http" else {
            return nil
        }
        let path = components.path
        let trimmedPath = path == "/" ? "" : path
        let readable = host + trimmedPath
        return readable.isEmpty ? nil : String(readable.prefix(200))
    }
}
