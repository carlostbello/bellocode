import AppKit
import BelloCore
import Foundation
import Synchronization
import Testing

@testable import TranscriptKit

/// Review finding M7 (docs/reviews/M2-M4-review.md): image metadata (rows per source, pixel sizes, requests,
/// failures) stays bounded across image-heavy threads and thread switches, and failed or interrupted loads are retried
/// when a thread is revisited.
@Suite(.serialized) @MainActor struct ImageMetadataTests {
    /// Counts loads per source; fails sources containing "broken" on their first attempt.
    final class Loader: TranscriptImageLoading {
        let calls = Mutex<[String: Int]>([:])

        func count(_ source: String) -> Int { calls.withLock { $0[source] ?? 0 } }

        func load(_ source: String) async -> LoadedImage? {
            let attempt = calls.withLock { calls -> Int in
                calls[source, default: 0] += 1
                return calls[source]!
            }
            if source.contains("broken"), attempt == 1 { return nil }
            let context = CGContext(
                data: nil, width: 64, height: 32, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            return LoadedImage(image: context.makeImage()!, pixelSize: CGSize(width: 64, height: 32))
        }
    }

    static func thread(_ number: Int, images: Int) -> StaticTranscriptSource {
        let session = SessionID("ses_images_\(number)")
        let user = MessageID("msg_t\(number)_user")
        let reply = MessageID("msg_t\(number)_reply")
        let parts = (0..<images).map { index in
            let name = index == 0 ? "broken" : "shot"
            return Part(
                id: Part.makeID(message: reply, .file(index: index)), index: index,
                content: .file(FileReference(uri: "test://thread\(number)/\(name)-\(index).png", mime: "image/png", name: "\(name)-\(index).png")))
        }
        return StaticTranscriptSource(messages: [
            Message(id: user, sessionID: session, kind: .user(UserContent(text: "Show run \(number)")), created: Timestamp(milliseconds: 1.8e12)),
            Message(
                id: reply, sessionID: session, kind: .assistant(AssistantInfo(finish: "stop", isOpen: false)), created: Timestamp(milliseconds: 1.8e12 + 1),
                parts: parts),
        ])
    }

    @Test func metadataStaysBoundedAcrossThreadSwitchesAndFailedLoadsRetry() async {
        _ = NSApplication.shared
        let loader = Loader()
        let controller = TranscriptController(imageLoader: loader)
        let viewController = TranscriptViewController(controller: controller)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 1_600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = viewController
        window.setContentSize(NSSize(width: 800, height: 1_600))
        viewController.view.layoutSubtreeIfNeeded()
        defer {
            controller.close()
            window.close()
        }
        func settle() async {
            for _ in 0..<200 {
                await controller.settle()
                if controller.imageTasks.isEmpty { break }
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        controller.imageByteLimit = 12 * 64 * 32 * 4  // a dozen decoded images
        controller.imageSizeLimit = 40
        let threads = 30
        let perThread = 6
        for number in 0..<threads {
            viewController.bind(Self.thread(number, images: perThread))
            await settle()
            #expect(loader.count("test://thread\(number)/shot-1.png") == 1, "thread \(number) loaded its images")
        }
        // 180 distinct sources were shown; per-source metadata must not keep all of them.
        let seen = threads * perThread
        #expect(controller.imageRows.count <= perThread, "rows per source: \(controller.imageRows.count) of \(seen)")
        #expect(controller.imageSizes.count <= 40, "sizes \(controller.imageSizes.count), decoded \(controller.images.count)")
        #expect(controller.imageSizeTick.count == controller.imageSizes.count)
        #expect(controller.imageTasks.isEmpty && controller.imageFailures.count <= 1)

        // Revisiting a thread retries the load that failed there.
        #expect(loader.count("test://thread0/broken-0.png") == 1)
        viewController.bind(Self.thread(0, images: perThread))
        await settle()
        #expect(loader.count("test://thread0/broken-0.png") == 2, "the failed load is retried on revisit")
        #expect(controller.isImageLoaded("test://thread0/broken-0.png"))
    }
}
