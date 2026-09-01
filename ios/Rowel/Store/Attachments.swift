/// The bytes behind an image a message refers to.
///
/// A history page names its images rather than carrying them: the event log
/// holds an `attachmentId` and the size, and the pixels stay on the Mac. That
/// is the right trade for a phone — one full-size photo is larger than the
/// entire rest of a long conversation, and scrolling back would pay for it
/// again on every page — but it means a reference on its own draws nothing.
/// This is the other half: ask for the bytes when something is actually about
/// to put them on screen.
///
/// What it keeps is the *thumbnail*, never the photo. A 12-megapixel image
/// decoded whole is around 48 MB of bitmap to fill a 56-point square, and a
/// conversation with a handful of them would be the largest thing in the app
/// by an order of magnitude. ImageIO downsamples while decoding, so the full
/// resolution never exists in this process at all.

import Foundation
import Observation
#if canImport(UIKit)
import ImageIO
import UIKit
#endif

#if canImport(UIKit)

/// Loads and remembers the thumbnails for one conversation's attachments.
@MainActor
@Observable
public final class AttachmentLoader {
    private let harness: Harness
    private let sessionId: String
    /// Thumbnails already decoded, by attachment id.
    private var thumbnails: [String: UIImage] = [:]
    /// Ids being fetched, so a redraw mid-flight does not ask twice.
    private var inflight: Set<String> = []

    /// - Parameters:
    ///   - harness: the machine holding the bytes.
    ///   - sessionId: the conversation the ids belong to.
    public init(harness: Harness, sessionId: String) {
        self.harness = harness
        self.sessionId = sessionId
    }

    /// The thumbnail for an attachment, if it has been fetched.
    /// - Parameter id: the attachment id from the message.
    /// - Returns: the decoded thumbnail, or nil when it is not here yet.
    public func thumbnail(_ id: String) -> UIImage? {
        thumbnails[id]
    }

    /// Fetch and decode one attachment, once.
    ///
    /// Failure is silent on purpose. The thumb already draws a placeholder,
    /// and a message that could not fetch its own image is not something the
    /// person can act on — a row of error badges down a transcript would be
    /// noise about the machine's plumbing, not about the conversation.
    /// - Parameters:
    ///   - id: the attachment id from the message.
    ///   - side: the point size the thumbnail is drawn at.
    public func load(_ id: String, side: CGFloat) async {
        if thumbnails[id] != nil || inflight.contains(id) { return }
        inflight.insert(id)
        defer { inflight.remove(id) }
        guard let (_, base64) = try? await harness.attachment(sessionId: sessionId, attachmentId: id),
              let data = Data(base64Encoded: base64) else { return }
        let pixels = side * (UITraitCollection.current.displayScale)
        guard let image = await downsample(data, to: pixels) else { return }
        thumbnails[id] = image
    }
}

/// Decode an image at thumbnail size without ever holding it at full size.
/// - Parameters:
///   - data: the encoded image.
///   - pixels: the longest edge to produce, in pixels.
/// - Returns: the thumbnail, or nil when the data is not an image.
private func downsample(_ data: Data, to pixels: CGFloat) async -> UIImage? {
    await Task.detached(priority: .userInitiated) {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, Int(pixels.rounded())),
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        return UIImage(cgImage: cgImage)
    }.value
}

#endif
