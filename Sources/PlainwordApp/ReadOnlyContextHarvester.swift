import ApplicationServices
import CoreGraphics
import Foundation
import PlainwordCore

/// Collects typed, read-only context from the interface surrounding an editable field.
///
/// The work runs on its own actor rather than on the main actor because a single harvest
/// issues hundreds of synchronous Accessibility round trips. In a browser or an Electron
/// application those are slow enough to be visible as a stall, and the field capture that
/// precedes this has already produced everything needed to show UI.
///
/// Being an actor also serialises harvests: two overlapping requests would otherwise
/// flood the same target application with Accessibility traffic.
actor ReadOnlyContextHarvester {
    /// Wall-clock ceiling for one harvest. Reaching it degrades the result rather than
    /// failing it, so the traversal below is ordered to visit the most valuable nodes
    /// first — see `expand`.
    private let maximumDuration: CFTimeInterval = 0.12

    /// Ceiling on Accessibility round trips, counted per node examined.
    private let maximumTraversalNodes = 240
    /// Counted from an ancestor, whose own children — the branches beside the focused
    /// field — are therefore at depth 1.
    private let maximumTraversalDepth = 13
    private let maximumAncestorDepth = 14
    private let maximumFragments = 6
    private let minimumRelevance = 300

    private let headingRole = "AXHeading"
    private let readableContextRoles: Set<String> = [
        kAXStaticTextRole as String,
        kAXTextFieldRole as String,
        kAXTextAreaRole as String,
        "AXHeading"
    ]
    private let contextViewportRoles: Set<String> = [
        kAXScrollAreaRole as String,
        "AXWebArea",
        "AXDocument"
    ]

    private struct NodeMetadata {
        let role: String?
        let frame: CGRect?
        let isHidden: Bool
        let isEditable: Bool
        let isProtected: Bool
    }

    private struct AncestorLevel {
        let childOnFocusedPath: AXUIElement
        let parent: AXUIElement
        let metadata: NodeMetadata
        let distance: Int
    }

    /// A node waiting to be examined, ordered by how close it sits to the focused field.
    private struct FrontierNode {
        let element: AXUIElement
        let metadata: NodeMetadata
        /// How many levels above the focused field this node's subtree was entered from.
        let ancestorDistance: Int
        let depth: Int
        let priority: Double
        let sequence: Int
    }

    /// What one harvest actually managed to look at, for diagnosing a thin result.
    struct Telemetry: Sendable {
        var nodesExamined = 0
        var reachedNodeLimit = false
        var reachedTimeLimit = false
        var durationSeconds: CFTimeInterval = 0

        var wasTruncated: Bool { reachedNodeLimit || reachedTimeLimit }
    }

    struct Result: Sendable {
        let fragments: [ReadOnlyContextFragment]
        let telemetry: Telemetry
    }

    func fragments(
        around focusedElement: AXElementBox,
        excluding excludedTexts: [String],
        targetUTF16Length: Int,
        primaryScreenMaxY: CGFloat
    ) -> Result {
        let startedAt = CFAbsoluteTimeGetCurrent()
        let deadline = startedAt + maximumDuration
        let budget = ReadOnlyContextGeometry.budgetUTF16Length(
            targetUTF16Length: targetUTF16Length
        )
        let element = focusedElement.element
        var telemetry = Telemetry()

        var candidates = directCandidates(
            around: element,
            deadline: deadline,
            primaryScreenMaxY: primaryScreenMaxY
        )
        let ancestorLevels = ancestors(
            of: element,
            deadline: deadline,
            primaryScreenMaxY: primaryScreenMaxY
        )
        candidates += documentTitleCandidates(from: ancestorLevels, deadline: deadline)

        func finish(_ maximumFragments: Int) -> Result {
            telemetry.durationSeconds = CFAbsoluteTimeGetCurrent() - startedAt
            return Result(
                fragments: ReadOnlyContextRanker.select(
                    from: candidates,
                    excluding: excludedTexts,
                    maximumUTF16Length: budget,
                    maximumFragments: maximumFragments,
                    minimumRelevance: minimumRelevance
                ),
                telemetry: telemetry
            )
        }

        guard let focusedFrame = AccessibilityElementReader.rect(
            of: element,
            primaryScreenMaxY: primaryScreenMaxY
        ), focusedFrame != .zero else {
            // Without geometry there is nothing to rank nearby content by, so only the
            // explicit accessibility relationships above are trustworthy.
            return finish(4)
        }

        candidates += nearbyCandidates(
            from: ancestorLevels,
            focusedElement: element,
            focusedFrame: focusedFrame,
            deadline: deadline,
            primaryScreenMaxY: primaryScreenMaxY,
            telemetry: &telemetry
        )
        return finish(maximumFragments)
    }

    // MARK: - Nearby content

    private func nearbyCandidates(
        from ancestorLevels: [AncestorLevel],
        focusedElement: AXUIElement,
        focusedFrame: CGRect,
        deadline: CFAbsoluteTime,
        primaryScreenMaxY: CGFloat,
        telemetry: inout Telemetry
    ) -> [ReadOnlyContextCandidate] {
        let windowFrame = ancestorLevels.first {
            $0.metadata.role == kAXWindowRole as String
        }?.metadata.frame
        let viewportFrame = viewportFrame(
            from: ancestorLevels,
            containing: focusedFrame
        ) ?? windowFrame
        let searchBounds = ReadOnlyContextGeometry.searchBounds(
            around: focusedFrame,
            clippedTo: viewportFrame
        )

        var candidates: [ReadOnlyContextCandidate] = []
        var remainingNodes = maximumTraversalNodes
        var sequence = 0
        var frontier: [FrontierNode] = []

        // Everything on the path from the focused field up to the window is spoken for:
        // the field itself, and every ancestor, which is seeded below rather than
        // rediscovered while enumerating somebody's children. Marking them here — before
        // any seeding — means expanding an ancestor only ever yields its other branches.
        var visited: Set<AXElementKey> = [AXElementKey(focusedElement)]
        for level in ancestorLevels {
            visited.insert(AXElementKey(level.childOnFocusedPath))
            visited.insert(AXElementKey(level.parent))
        }

        // Seeding with the ancestors themselves costs no extra round trips: their
        // metadata was already read while walking up, so none of them spends the node
        // budget. Every ancestor contains the focused field and so scores a proximity of
        // zero; the tie-break on `ancestorDistance` makes the tightest container expand
        // first, which is the shortest path to the content beside the field.
        //
        // The walk visits each ancestor exactly once, so these are distinct by
        // construction and need no membership check of their own.
        for level in ancestorLevels
        where !level.metadata.isHidden && !level.metadata.isProtected {
            frontier.append(
                FrontierNode(
                    element: level.parent,
                    metadata: level.metadata,
                    ancestorDistance: level.distance,
                    depth: 0,
                    priority: 0,
                    sequence: sequence
                )
            )
            sequence += 1
        }

        while !frontier.isEmpty {
            guard remainingNodes > 0 else {
                telemetry.reachedNodeLimit = true
                break
            }
            guard CFAbsoluteTimeGetCurrent() < deadline else {
                telemetry.reachedTimeLimit = true
                break
            }

            var nearestIndex = 0
            for index in frontier.indices.dropFirst()
            where Self.isCloser(frontier[index], than: frontier[nearestIndex]) {
                nearestIndex = index
            }
            let node = frontier.remove(at: nearestIndex)

            if let candidate = readableCandidate(
                for: node,
                focusedFrame: focusedFrame
            ) {
                candidates.append(candidate)
                // Readable text is a leaf as far as context goes; its children are runs
                // and glyphs that would only repeat what was just captured.
                continue
            }

            for child in childElements(of: node.element) {
                admit(
                    child,
                    ancestorDistance: node.ancestorDistance,
                    depth: node.depth + 1,
                    inheritedPriority: node.priority,
                    focusedFrame: focusedFrame,
                    searchBounds: searchBounds,
                    primaryScreenMaxY: primaryScreenMaxY,
                    remainingNodes: &remainingNodes,
                    sequence: &sequence,
                    visited: &visited,
                    frontier: &frontier,
                    telemetry: &telemetry
                )
            }
        }

        return candidates
    }

    /// Nearest first, then the shallowest ancestry, then discovery order.
    private static func isCloser(_ lhs: FrontierNode, than rhs: FrontierNode) -> Bool {
        if lhs.priority != rhs.priority { return lhs.priority < rhs.priority }
        if lhs.ancestorDistance != rhs.ancestorDistance {
            return lhs.ancestorDistance < rhs.ancestorDistance
        }
        return lhs.sequence < rhs.sequence
    }

    private func admit(
        _ element: AXUIElement,
        ancestorDistance: Int,
        depth: Int,
        inheritedPriority: Double,
        focusedFrame: CGRect,
        searchBounds: CGRect,
        primaryScreenMaxY: CGFloat,
        remainingNodes: inout Int,
        sequence: inout Int,
        visited: inout Set<AXElementKey>,
        frontier: inout [FrontierNode],
        telemetry: inout Telemetry
    ) {
        guard depth <= maximumTraversalDepth else { return }
        guard remainingNodes > 0 else {
            telemetry.reachedNodeLimit = true
            return
        }
        guard visited.insert(AXElementKey(element)).inserted else { return }

        remainingNodes -= 1
        telemetry.nodesExamined += 1
        let metadata = nodeMetadata(element, primaryScreenMaxY: primaryScreenMaxY)
        guard !metadata.isHidden, !metadata.isProtected else { return }

        let priority: Double
        if let frame = metadata.frame {
            guard frame.intersects(searchBounds) || frame.contains(focusedFrame) else {
                return
            }
            priority = ReadOnlyContextGeometry.proximity(of: frame, to: focusedFrame)
        } else {
            // Frameless grouping nodes are common in web content. Exploring them where
            // their parent sat keeps a whole subtree from being deferred behind content
            // that is further away.
            priority = inheritedPriority
        }

        frontier.append(
            FrontierNode(
                element: element,
                metadata: metadata,
                ancestorDistance: ancestorDistance,
                depth: depth,
                priority: priority,
                sequence: sequence
            )
        )
        sequence += 1
    }

    private func readableCandidate(
        for node: FrontierNode,
        focusedFrame: CGRect
    ) -> ReadOnlyContextCandidate? {
        guard let role = node.metadata.role,
              readableContextRoles.contains(role),
              !node.metadata.isEditable,
              !isWritableReadableElement(role: role, element: node.element),
              let frame = node.metadata.frame,
              let text = AccessibilityElementReader.readableText(from: node.element) else {
            return nil
        }
        return ReadOnlyContextGeometry.candidate(
            text: text,
            isHeading: role == headingRole,
            frame: frame,
            focusedFrame: focusedFrame,
            ancestorDistance: node.ancestorDistance
        )
    }

    // MARK: - Explicit relationships

    private func directCandidates(
        around focusedElement: AXUIElement,
        deadline: CFAbsoluteTime,
        primaryScreenMaxY: CGFloat
    ) -> [ReadOnlyContextCandidate] {
        let attributes = [
            kAXTitleAttribute as String,
            kAXPlaceholderValueAttribute as String,
            kAXDescriptionAttribute as String,
            kAXHelpAttribute as String,
            kAXTitleUIElementAttribute as String,
            kAXLinkedUIElementsAttribute as String
        ]
        let values = AccessibilityElementReader.multipleAttributeValues(
            attributes,
            from: focusedElement
        )
        var candidates: [ReadOnlyContextCandidate] = []

        func appendString(_ attribute: String, kind: ReadOnlyContextKind, relevance: Int) {
            guard let text = AccessibilityElementReader.stringValue(values[attribute]) else {
                return
            }
            candidates.append(
                .init(
                    kind: kind,
                    text: text,
                    relevance: relevance,
                    readingOrder: ReadOnlyContextGeometry.metadataReadingOrder
                )
            )
        }

        // AXTitle and AXDescription can both carry the accessible name depending
        // on the target framework. Keep them as field identity instead of
        // claiming a label/description distinction that the API cannot guarantee.
        appendString(kAXTitleAttribute as String, kind: .fieldIdentity, relevance: 970)
        appendString(
            kAXPlaceholderValueAttribute as String,
            kind: .fieldPlaceholder,
            relevance: 820
        )
        appendString(
            kAXDescriptionAttribute as String,
            kind: .fieldIdentity,
            relevance: 950
        )
        appendString(
            kAXHelpAttribute as String,
            kind: .fieldHelp,
            relevance: 310
        )

        if let titleElement = AccessibilityElementReader.uiElementValue(
            values[kAXTitleUIElementAttribute as String]
        ),
           !AccessibilityElementReader.isProtected(titleElement),
           let title = AccessibilityElementReader.readableText(from: titleElement) {
            candidates.append(
                .init(
                    kind: .fieldLabel,
                    text: title,
                    relevance: 1_100,
                    readingOrder: ReadOnlyContextGeometry.metadataReadingOrder
                )
            )
        }

        for (index, linkedElement) in AccessibilityElementReader.uiElementArray(
            values[kAXLinkedUIElementsAttribute as String]
        ).prefix(3).enumerated() {
            guard CFAbsoluteTimeGetCurrent() < deadline else { break }
            if let candidate = validatedLinkedCandidate(
                from: linkedElement,
                around: focusedElement,
                readingOrder: ReadOnlyContextGeometry.metadataReadingOrder + index,
                relevance: 520 - index * 10,
                primaryScreenMaxY: primaryScreenMaxY
            ) {
                candidates.append(candidate)
            }
        }
        return candidates
    }

    private func validatedLinkedCandidate(
        from linkedElement: AXUIElement,
        around focusedElement: AXUIElement,
        readingOrder: Int,
        relevance: Int,
        primaryScreenMaxY: CGFloat
    ) -> ReadOnlyContextCandidate? {
        let metadata = nodeMetadata(linkedElement, primaryScreenMaxY: primaryScreenMaxY)
        guard let role = metadata.role,
              readableContextRoles.contains(role),
              !metadata.isHidden,
              !metadata.isProtected,
              !metadata.isEditable,
              !isWritableReadableElement(role: role, element: linkedElement),
              sharesWindow(linkedElement, with: focusedElement),
              let focusedFrame = AccessibilityElementReader.rect(
                of: focusedElement,
                primaryScreenMaxY: primaryScreenMaxY
              ),
              let linkedFrame = metadata.frame,
              ReadOnlyContextGeometry.isRelevant(linkedFrame, to: focusedFrame),
              let text = AccessibilityElementReader.readableText(from: linkedElement) else {
            return nil
        }
        return .init(
            kind: .relatedContent,
            text: text,
            relevance: relevance,
            readingOrder: readingOrder
        )
    }

    private func sharesWindow(
        _ linkedElement: AXUIElement,
        with focusedElement: AXUIElement
    ) -> Bool {
        guard let linkedWindow = AccessibilityElementReader.elementAttribute(
            kAXWindowAttribute as String,
            from: linkedElement
        ),
              let focusedWindow = AccessibilityElementReader.elementAttribute(
                kAXWindowAttribute as String,
                from: focusedElement
              ) else {
            // Some web accessibility nodes omit AXWindow. Geometry validation
            // still provides a conservative fallback in that case.
            return true
        }
        return AccessibilityElementReader.elementsAreEqual(linkedWindow, focusedWindow)
    }

    // MARK: - Ancestry

    private func ancestors(
        of focusedElement: AXUIElement,
        deadline: CFAbsoluteTime,
        primaryScreenMaxY: CGFloat
    ) -> [AncestorLevel] {
        var levels: [AncestorLevel] = []
        var currentElement = focusedElement
        for distance in 0..<maximumAncestorDepth {
            guard CFAbsoluteTimeGetCurrent() < deadline else { break }
            guard let parent = AccessibilityElementReader.elementAttribute(
                kAXParentAttribute as String,
                from: currentElement
            ) else {
                break
            }
            let metadata = nodeMetadata(parent, primaryScreenMaxY: primaryScreenMaxY)
            levels.append(
                AncestorLevel(
                    childOnFocusedPath: currentElement,
                    parent: parent,
                    metadata: metadata,
                    distance: distance
                )
            )
            if metadata.role == kAXWindowRole as String { break }
            currentElement = parent
        }
        return levels
    }

    private func documentTitleCandidates(
        from ancestorLevels: [AncestorLevel],
        deadline: CFAbsoluteTime
    ) -> [ReadOnlyContextCandidate] {
        var candidates: [ReadOnlyContextCandidate] = []
        for level in ancestorLevels where isDocumentContextRole(level.metadata.role) {
            guard CFAbsoluteTimeGetCurrent() < deadline else { break }
            if let title = AccessibilityElementReader.stringAttribute(
                kAXTitleAttribute as String,
                from: level.parent
            ) {
                candidates.append(
                    .init(
                        kind: .documentTitle,
                        text: title,
                        relevance: 850 - level.distance * 20,
                        readingOrder: ReadOnlyContextGeometry.metadataReadingOrder
                            + level.distance
                    )
                )
            }
        }
        return candidates
    }

    private func viewportFrame(
        from ancestorLevels: [AncestorLevel],
        containing focusedFrame: CGRect
    ) -> CGRect? {
        ancestorLevels.lazy.compactMap { level -> CGRect? in
            guard let role = level.metadata.role,
                  self.contextViewportRoles.contains(role),
                  let frame = level.metadata.frame,
                  frame != .zero,
                  frame.intersects(focusedFrame) || frame.contains(focusedFrame) else {
                return nil
            }
            return frame
        }.first
    }

    private func isDocumentContextRole(_ role: String?) -> Bool {
        guard let role else { return false }
        return role == kAXWindowRole as String
            || role == "AXWebArea"
            || role == "AXDocument"
    }

    // MARK: - Node reads

    private func nodeMetadata(
        _ element: AXUIElement,
        primaryScreenMaxY: CGFloat
    ) -> NodeMetadata {
        let attributes = [
            kAXRoleAttribute as String,
            kAXPositionAttribute as String,
            kAXSizeAttribute as String,
            kAXHiddenAttribute as String,
            kAXIsEditableAttribute as String,
            AccessibilityElementReader.protectedContentAttribute
        ]
        let values = AccessibilityElementReader.multipleAttributeValues(
            attributes,
            from: element
        )
        return NodeMetadata(
            role: AccessibilityElementReader.stringValue(values[kAXRoleAttribute as String]),
            frame: frame(from: values, primaryScreenMaxY: primaryScreenMaxY),
            isHidden: AccessibilityElementReader.boolValue(
                values[kAXHiddenAttribute as String]
            ),
            isEditable: AccessibilityElementReader.boolValue(
                values[kAXIsEditableAttribute as String]
            ),
            isProtected: AccessibilityElementReader.boolValue(
                values[AccessibilityElementReader.protectedContentAttribute]
            )
        )
    }

    private func frame(
        from values: [String: Any],
        primaryScreenMaxY: CGFloat
    ) -> CGRect? {
        guard let positionValue = AccessibilityElementReader.axValue(
            values[kAXPositionAttribute as String]
        ),
              let sizeValue = AccessibilityElementReader.axValue(
                values[kAXSizeAttribute as String]
              ) else {
            return nil
        }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &position),
              AXValueGetValue(sizeValue, .cgSize, &size) else {
            return nil
        }
        return AccessibilityElementReader.appKitRect(
            fromAccessibilityRect: CGRect(origin: position, size: size),
            primaryScreenMaxY: primaryScreenMaxY
        )
    }

    private func childElements(of element: AXUIElement) -> [AXUIElement] {
        let navigationOrderAttribute = "AXChildrenInNavigationOrder"
        let attributes = [
            kAXContentsAttribute as String,
            navigationOrderAttribute,
            kAXVisibleChildrenAttribute as String
        ]
        let values = AccessibilityElementReader.multipleAttributeValues(
            attributes,
            from: element
        )
        let contentChildren = AccessibilityElementReader.uiElementArray(
            values[kAXContentsAttribute as String]
        )
        let navigationOrder = AccessibilityElementReader.uiElementArray(
            values[navigationOrderAttribute]
        )
        let visibleChildren = AccessibilityElementReader.uiElementArray(
            values[kAXVisibleChildrenAttribute as String]
        )

        if !contentChildren.isEmpty {
            let visible = Set(visibleChildren.map(AXElementKey.init))
            let visibleContent = visible.isEmpty
                ? contentChildren
                : contentChildren.filter { visible.contains(AXElementKey($0)) }
            let eligibleContent = visibleContent.isEmpty ? contentChildren : visibleContent
            return ordering(eligibleContent, by: navigationOrder)
        }

        if !navigationOrder.isEmpty, !visibleChildren.isEmpty {
            return ordering(visibleChildren, by: navigationOrder)
        }
        if !visibleChildren.isEmpty { return visibleChildren }
        if !navigationOrder.isEmpty { return navigationOrder }
        return AccessibilityElementReader.uiElementArray(
            AccessibilityElementReader.attributeValue(
                kAXChildrenAttribute as String,
                from: element
            )
        )
    }

    /// Sorts `elements` into the sequence given by `preferredOrder`, appending anything
    /// the preferred order does not mention.
    private func ordering(
        _ elements: [AXUIElement],
        by preferredOrder: [AXUIElement]
    ) -> [AXUIElement] {
        guard !preferredOrder.isEmpty else { return elements }
        let eligible = Set(elements.map(AXElementKey.init))
        var ordered = preferredOrder.filter { eligible.contains(AXElementKey($0)) }
        var placed = Set(ordered.map(AXElementKey.init))
        for element in elements where placed.insert(AXElementKey(element)).inserted {
            ordered.append(element)
        }
        return ordered.isEmpty ? elements : ordered
    }

    private func isWritableReadableElement(role: String, element: AXUIElement) -> Bool {
        guard role == kAXTextFieldRole as String
                || role == kAXTextAreaRole as String
                || role == kAXComboBoxRole as String else {
            return false
        }
        return AccessibilityElementReader.isWritableTextElement(element)
    }
}
