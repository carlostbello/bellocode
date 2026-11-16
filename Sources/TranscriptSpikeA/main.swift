// G1-A spike harness. `TranscriptSpikeA --scenario S1|S2|S3|S4|S5|S6|S7|S8|huge|find|look`
// writes build/spikes/G1-A/<scenario>.json and build/snapshots/G1-A-*.png, then exits.

import AppKit
import ObjectiveC
import QuartzCore
import TranscriptKit

let processStart = CACurrentMediaTime()
let arguments = CommandLine.arguments
func argument(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}
let scenario = argument("--scenario") ?? "look"
if let root = argument("--root") { Output.root = URL(fileURLWithPath: root) }

// Log Objective-C exceptions (AppKit swallows the reason when it crashes on an exception in a display flush).
_ = objc_setExceptionPreprocessor { exception in
    if let exception = exception as? NSException {
        let stack = Thread.callStackSymbols.prefix(30).joined(separator: "\n")
        FileHandle.standardError.write(Data("[G1-A] EXCEPTION \(exception.name.rawValue): \(exception.reason ?? "")\n\(stack)\n".utf8))
    }
    return exception
}

let application = NSApplication.shared
application.setActivationPolicy(.regular)

Task { @MainActor in
    log("scenario \(scenario)")
    let started = CACurrentMediaTime()
    let transcript = await generateWorkload()
    let generationMS = (CACurrentMediaTime() - started) * 1_000
    log("workload: \(transcript.stats.messages) messages, \(transcript.stats.totalUTF8Bytes) bytes in \(Int(generationMS)) ms")
    let harness = Harness(transcript: transcript, generationMS: generationMS)
    let scenarios = Scenarios(harness: harness, processStart: processStart)
    await scenarios.run(scenario)
    log("done")
    exit(0)
}

@concurrent func generateWorkload() async -> SpikeTranscript { SpikeWorkload.generate() }

application.run()
