/// Images a message refers to but does not carry.
///
/// A history page names its images: `session.attachment` holds the bytes and
/// the event log holds only an id. The app had the parser for the reference
/// and the call for the bytes and nothing in between, so every photo in a
/// transcript drew the placeholder forever. These tests are that gap.
///
/// The `session.attachment` shape below is measured, not invented — it is what
/// a live dsh answered for a real image in a real session.

import XCTest
#if canImport(UIKit)
import UIKit
#endif
@testable import Rowel

/// A transport that answers `session.attachment` and counts the asking.
private actor CountingTransport: HarnessTransport {
    private(set) var calls = 0
    private let data: String

    init(base64 data: String) {
        self.data = data
    }

    func call(_ method: String, _ payload: JSONValue) async throws -> JSONValue {
        guard method == "session.attachment" else {
            throw CallError(code: "not-found", message: "no script for \(method)", details: .null)
        }
        calls += 1
        return .object([
            "attachment": .object([
                "attachmentId": payload["attachmentId"] ?? .null,
                "mediaType": .string("image/png"),
                "bytes": .number(66594),
                "name": .string("uber_cover.jpg"),
            ]),
            "data": .string(data),
        ])
    }

    func respond(rpcId: String, value: JSONValue) async throws -> JSONValue {
        .emptyObject
    }
}

final class AttachmentTests: XCTestCase {
    /// The pixel width of the test photo, standing in for something off a camera.
    private static let sourcePixels: CGFloat = 1200

    /// A real PNG at a known pixel size. Scale 1 so points and pixels agree and
    /// the assertions below are about the decode, not about the test device.
    private static func png() -> String {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let size = CGSize(width: sourcePixels, height: sourcePixels * 0.75)
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        return image.pngData()!.base64EncodedString()
    }

    @MainActor
    func testAReferencedImageIsFetchedAndDecoded() async throws {
        let transport = CountingTransport(base64: AttachmentTests.png())
        let loader = AttachmentLoader(harness: Harness(transport: transport), sessionId: "session-1")
        let id = "sha256:125788fcf3572ebc4adcb18361a966c8073d5a152563395b6e9814057dcd8809"

        XCTAssertNil(loader.thumbnail(id), "nothing is fetched before something needs to draw it")
        await loader.load(id, side: 56)

        XCTAssertNotNil(loader.thumbnail(id), "the placeholder is only correct until the bytes arrive")
    }

    @MainActor
    func testTheThumbnailIsSmallerThanTheImage() async throws {
        let transport = CountingTransport(base64: AttachmentTests.png())
        let loader = AttachmentLoader(harness: Harness(transport: transport), sessionId: "session-1")
        await loader.load("sha256:a", side: 56)

        // A phone that keeps full-size photos to fill 56-point squares runs out
        // of memory on a conversation with a handful of them. `UIImage(cgImage:)`
        // is scale 1, so `size` here is in pixels.
        let thumbnail = try XCTUnwrap(loader.thumbnail("sha256:a"))
        let longest = max(thumbnail.size.width, thumbnail.size.height)
        XCTAssertLessThan(longest, AttachmentTests.sourcePixels,
                          "the decode produced the original, not a thumbnail")
        XCTAssertLessThanOrEqual(longest, 56 * UITraitCollection.current.displayScale,
                                 "the thumbnail is larger than the square it fills")
    }

    @MainActor
    func testTheSameImageIsAskedForOnce() async throws {
        let transport = CountingTransport(base64: AttachmentTests.png())
        let loader = AttachmentLoader(harness: Harness(transport: transport), sessionId: "session-1")

        // A transcript redraws constantly; scrolling past one photo must not
        // re-fetch it every frame.
        await loader.load("sha256:a", side: 56)
        await loader.load("sha256:a", side: 56)
        await loader.load("sha256:a", side: 56)

        let calls = await transport.calls
        XCTAssertEqual(calls, 1)
    }

    /// The reference shape the parser has to recognise, measured off a live dsh.
    @MainActor
    func testHistoryCarriesTheIdAndNoBytes() throws {
        let conversation = Conversation(sessionId: "session-1")
        conversation.apply(event: .object([
            "type": .string("user/message"),
            "seq": .number(12),
            // `data` is the message itself, verified against a live dsh.
            "data": .object([
                "id": .string("m1"),
                "source": .object(["kind": .string("user")]),
                "content": .array([
                    .object(["type": .string("text"), "text": .string("look at this")]),
                    .object([
                        "type": .string("image"),
                        "attachment": .object([
                            "attachmentId": .string("sha256:abc"),
                            "mediaType": .string("image/png"),
                            "bytes": .number(66594),
                        ]),
                    ]),
                ]),
            ]),
        ]), view: nil)

        guard case .user(let turn)? = conversation.items.last else {
            return XCTFail("the message did not land as a user turn")
        }
        XCTAssertEqual(turn.images.map(\.id), ["sha256:abc"])
        XCTAssertNil(turn.images.first?.base64, "the bytes stay on the Mac until asked for")
    }
}
