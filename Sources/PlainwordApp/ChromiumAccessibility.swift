import AppKit
import ApplicationServices
import Foundation

/// Keeps a Chromium-based application's accessibility tree alive long enough to be read.
///
/// Chromium builds no accessibility tree until it believes assistive software is
/// watching, and — this is the part that catches a tool like this one — it tears the
/// tree back down again when it decides nobody is. The rule it uses is that three or
/// more input events in web content over more than thirty seconds, with no accessibility
/// calls in that time, mean the client has gone away. An author typing a paragraph
/// before asking for help satisfies it exactly, so by the time the shortcut is pressed
/// the page has no tree to read and the harvest comes back with a field label and
/// nothing else.
///
/// Enabling it again is not instant either: the tree is built asynchronously, so the
/// first read after the switch is flipped finds a shape with no text in it yet.
///
/// So there are two jobs here — say once that we are watching, and keep saying it — and
/// both only make sense for the engine that behaves this way. Every Electron application
/// is this engine too, which is most of the software an author writes in.
enum ChromiumAccessibility {
    /// Comfortably inside the thirty seconds that would otherwise be counted against us,
    /// and rare enough to be free: one attribute read every fifteen seconds.
    static let keepAliveInterval: TimeInterval = 15

    /// How long to leave a tree that was just switched on before reading it again.
    static let treeBuildDelay: Duration = .milliseconds(150)

    /// Tells an application that assistive software is watching.
    ///
    /// Two attributes because the two families listen for different ones. Electron
    /// documents `AXManualAccessibility` as the opt-in for third-party assistive
    /// software; the Chrome-family browsers do not implement it and take
    /// `AXEnhancedUserInterface`, which is the flag VoiceOver sets.
    ///
    /// Only Chromium hosts are told. `AXEnhancedUserInterface` changes how some native
    /// applications lay themselves out and animate, and setting it on everything in
    /// reach to gain nothing would be rude in a way the author would eventually notice.
    static func activate(processIdentifier: pid_t) {
        let application = AXUIElementCreateApplication(processIdentifier)
        _ = AXUIElementSetAttributeValue(
            application,
            "AXManualAccessibility" as CFString,
            kCFBooleanTrue
        )
        _ = AXUIElementSetAttributeValue(
            application,
            "AXEnhancedUserInterface" as CFString,
            kCFBooleanTrue
        )
    }

    /// One cheap read against web content, so the idle rule never counts to three.
    static func ping(_ element: AXUIElement) {
        var value: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value)
    }

    // MARK: - Recognising the engine

    /// Whether an application draws its interface with Chromium.
    ///
    /// Decided from what the application is made of rather than from a list of the ones
    /// known to be Electron. A list of bundle identifiers is a claim about other
    /// people's software that goes quietly out of date — a new Electron application is
    /// released every week and would simply be missed — while every one of them, and
    /// every Chrome-family browser, ships the same engine in the same place under a name
    /// of the same shape.
    static func isChromiumHost(processIdentifier: pid_t) -> Bool {
        guard let application = NSRunningApplication(processIdentifier: processIdentifier),
              let bundleURL = application.bundleURL else {
            return false
        }
        return isChromiumBundle(bundleURL)
    }

    static func isChromiumBundle(_ bundleURL: URL) -> Bool {
        let manager = FileManager.default
        let frameworks = bundleURL.appending(path: "Contents/Frameworks")
        guard let entries = try? manager.contentsOfDirectory(
            at: frameworks,
            includingPropertiesForKeys: nil
        ) else {
            return false
        }

        for entry in entries {
            // An application embedding Chromium directly rather than through Electron
            // keeps its helpers beside the framework instead of inside it. Spotify is
            // laid out this way.
            if entry.pathExtension == "app",
               entry.deletingPathExtension().lastPathComponent.hasSuffix("(Renderer)") {
                return true
            }
            guard entry.pathExtension == "framework" else { continue }
            // "Electron Framework", "Google Chrome Framework", "Brave Browser
            // Framework", "Microsoft Edge Framework" — the engine is always named for
            // whoever shipped it, and always with that suffix.
            guard entry.deletingPathExtension().lastPathComponent.hasSuffix(" Framework")
            else {
                continue
            }
            // The name alone would be a guess. What settles it is the renderer: Chromium
            // puts every web page in a separate helper process, and that helper lives
            // inside the framework it belongs to.
            let versions = entry.appending(path: "Versions")
            guard let builds = try? manager.contentsOfDirectory(
                at: versions,
                includingPropertiesForKeys: nil
            ) else {
                continue
            }
            for build in builds
            where manager.fileExists(atPath: build.appending(path: "Helpers").path) {
                return true
            }
        }
        return false
    }
}
