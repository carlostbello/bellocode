import AppKit
import BelloCore
import SwiftUI

/// Versions shown in Settings ▸ General ▸ About and in the About panel: BelloCode's own and the bundled opencode
/// (`OpenCodePin`, written into Info.plist by Scripts/make-app.sh). A development build without a bundle names the
/// checkout's pin instead.
enum AboutInfo {
    static func appVersion(bundle: Bundle = .main) -> String {
        let short = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        switch (short, build) {
        case (let short?, let build?): return "\(short) (\(build))"
        case (let short?, nil): return short
        default: return "development build"
        }
    }

    static func openCodeVersion(bundle: Bundle = .main) -> String {
        if let bundled = OpenCodePin.bundledVersion(bundle: bundle) { return bundled }
        return OpenCodePin.repositoryVersion().map { "\($0) (not bundled: development build)" } ?? "unknown"
    }

    /// The About panel's credits line.
    static func credits(bundle: Bundle = .main) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        return NSAttributedString(
            string: "Bundled opencode \(openCodeVersion(bundle: bundle))\nLicences: Settings ▸ Acknowledgements",
            attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize), .foregroundColor: NSColor.secondaryLabelColor,
                         .paragraphStyle: style])
    }
}

extension NSApplication {
    /// BelloCode ▸ About BelloCode: the standard panel with the bundled opencode version in its credits.
    @objc func orderFrontBelloCodeAboutPanel(_ sender: Any?) {
        orderFrontStandardAboutPanel(options: [.credits: AboutInfo.credits()])
    }
}

/// Settings ▸ General ▸ About.
struct AboutSettingsGroup: View {
    var body: some View {
        SettingsGroup("About") {
            SettingsRow("BelloCode") { Text(AboutInfo.appVersion()).font(.ds(.label)).foregroundStyle(Color.ds.text2).textSelection(.enabled) }
            SettingsRow("Bundled opencode", divided: false) {
                Text(AboutInfo.openCodeVersion()).font(.ds(.label)).foregroundStyle(Color.ds.text2).textSelection(.enabled)
            }
        }
    }
}
