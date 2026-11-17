import AppKit
import DesignSystem

// DesignGallery: renders every DesignSystem token and control, in every state, in light and dark, to PNG.
//
//   swift run DesignGallery                 # writes build/snapshots/design/*.png
//   swift run DesignGallery --out <dir>
//   swift run DesignGallery --dump-tokens   # prints the token table (DS.dump())
//
// Rendering is in-process (`cacheDisplay`), which cannot capture NSVisualEffectView vibrancy, so glass surfaces are
// rendered with their solid Reduce Transparency fallback (`DSGlassView.forcesSolidFallback`).

let arguments = CommandLine.arguments

if arguments.contains("--dump-tokens") {
    print(DS.dump())
    exit(0)
}

let outIndex = arguments.firstIndex(of: "--out")
let outDirectory = URL(fileURLWithPath: outIndex.map { arguments[$0 + 1] } ?? "build/snapshots/design", isDirectory: true)

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    DS.Accent.ignoresUserAccent = true
    DSGlassView.forcesSolidFallback = true
    DS.Accessibility.reduceMotionOverride = true
    DSControl.focusPolicy = .always

    let sheets: [(String, () -> Sheet)] = [
        ("tokens", Sheets.tokens),
        ("controls", Sheets.controls),
        ("menus", Sheets.menus),
        ("composition", Sheets.composition),
    ]
    do {
        for (name, make) in sheets {
            for (appearance, suffix) in [(NSAppearance.Name.darkAqua, "dark"), (.aqua, "light")] {
                let url = outDirectory.appendingPathComponent("\(name)-\(suffix).png")
                try Renderer.render(make, appearance: appearance, to: url, smoothing: arguments.contains("--font-smoothing"))
                print("wrote \(url.path)")
            }
        }
    } catch {
        FileHandle.standardError.write(Data("DesignGallery failed: \(error)\n".utf8))
        exit(1)
    }
}
