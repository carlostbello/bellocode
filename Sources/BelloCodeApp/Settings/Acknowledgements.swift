import AppKit
import DesignSystem
import SwiftUI

/// What BelloCode builds on, with licences (Settings ▸ Acknowledgements; the About panel's credits name it).
/// T3 Code's notice is required by its MIT licence: the visual language (palette, metrics, recipes) is derived from it
/// (docs/design/visual-language.md, "Attribution"). Dependency licence texts are copied into the app bundle by
/// `Scripts/make-app.sh` (`Resources/Acknowledgements/<name>.txt`) and shown in full when present.
struct Acknowledgement: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let use: String
    let licence: String
    let url: String
    /// Full text embedded in the app (only where the bundle may not carry it).
    var text: String?

    static let t3CodeNotice = """
        MIT License

        Copyright (c) 2026 T3 Tools Inc.

        Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated \
        documentation files (the "Software"), to deal in the Software without restriction, including without limitation \
        the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to \
        permit persons to whom the Software is furnished to do so, subject to the following conditions:

        The above copyright notice and this permission notice shall be included in all copies or substantial portions of \
        the Software.

        THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO \
        THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE \
        AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, \
        TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE \
        SOFTWARE.
        """

    static let all: [Acknowledgement] = [
        Acknowledgement(
            name: "T3 Code", use: "Visual language: palette, metrics and component recipes (no logo, name or brand asset)",
            licence: "MIT", url: "https://github.com/pingdotgg/t3code", text: t3CodeNotice),
        Acknowledgement(name: "opencode", use: "The bundled agent server", licence: "MIT", url: "https://github.com/anomalyco/opencode"),
        Acknowledgement(name: "ripgrep", use: "File search for the bundled server", licence: "MIT or Unlicense", url: "https://github.com/BurntSushi/ripgrep"),
        Acknowledgement(name: "SwiftTerm", use: "Terminal emulator", licence: "MIT", url: "https://github.com/migueldeicaza/SwiftTerm"),
        Acknowledgement(name: "GRDB.swift", use: "SQLite cache", licence: "MIT", url: "https://github.com/groue/GRDB.swift"),
        Acknowledgement(name: "swift-markdown", use: "Markdown parsing", licence: "Apache 2.0", url: "https://github.com/swiftlang/swift-markdown"),
        Acknowledgement(name: "swift-cmark", use: "CommonMark parser under swift-markdown", licence: "BSD 2-Clause",
                        url: "https://github.com/swiftlang/swift-cmark"),
        Acknowledgement(name: "swift-argument-parser", use: "Command-line helper", licence: "Apache 2.0", url: "https://github.com/apple/swift-argument-parser"),
        Acknowledgement(name: "swift-png", use: "Image encoding", licence: "Apache 2.0", url: "https://github.com/tayloraswift/swift-png"),
        Acknowledgement(name: "h", use: "Dependency of swift-png", licence: "Apache 2.0", url: "https://github.com/rarestype/h"),
    ]

    /// The full licence text: embedded, else the copy in the app bundle (release builds), else nil.
    var fullText: String? {
        if let text { return text }
        guard let url = Bundle.main.resourceURL?.appending(path: "Acknowledgements/\(name).txt") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}

/// Settings ▸ Acknowledgements: one group of rows (name, what it is for, licence), and the selected entry's full text.
struct AcknowledgementsView: View {
    @StateObject private var selection = AcknowledgementSelection()

    var body: some View {
        SettingsPaneBody {
            SettingsGroup(
                "Built with",
                footer: "BelloCode's look is derived from T3 Code (MIT). No T3 logo, name, wordmark or other brand asset is used."
            ) {
                ForEach(Array(Acknowledgement.all.enumerated()), id: \.element.id) { index, item in
                    SettingsRow(item.name, detail: item.use, divided: index > 0) {
                        HStack(spacing: DS.Space.s6) {
                            DSPillView(item.licence)
                            Button(selection.shown == item.id ? "Hide" : "Licence") {
                                selection.shown = selection.shown == item.id ? nil : item.id
                            }
                            .buttonStyle(DSButtonStyle(.ghost, size: .small, isMuted: true))
                            .accessibilityLabel("\(selection.shown == item.id ? "Hide" : "Show") \(item.name) licence")
                        }
                    }
                }
            }
            if let id = selection.shown, let item = Acknowledgement.all.first(where: { $0.id == id }) {
                SettingsGroup(item.name) {
                    Text(item.fullText ?? "The licence text ships with release builds. Source: \(item.url)")
                        .font(.ds(.codeSmall)).foregroundStyle(Color.ds.text2).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(DS.Space.s12)
                }
            }
        }
    }
}

@MainActor
final class AcknowledgementSelection: ObservableObject {
    @Published var shown: String? = "T3 Code"
}
