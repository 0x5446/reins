/// Record one window, and nothing else that happens to be in front of it.
///
/// This exists because the obvious way — capture a rectangle of the display —
/// is not safe. A rectangle holds whatever is on top of it, and two takes of
/// the launch video came back containing windows belonging to the person
/// running the script, one of them a private conversation. There is no check
/// that fixes it: AppleScript will tell you a window exists and where it was
/// moved to, not that it is the thing visible at those coordinates.
///
/// ScreenCaptureKit answers a different question. A `SCContentFilter` built
/// from one `SCWindow` captures that window's contents whether or not anything
/// is drawn over it, so what comes out cannot contain a window nobody asked
/// for. The window is chosen by owning application and a substring of its
/// title, and if that matches anything other than exactly one window this
/// refuses rather than guesses.
///
///   swift ios/Tools/RecordWindow.swift --app "Google Chrome" \
///     --title "127.0.0.1:3082" --seconds 40 --out /tmp/mac.mov
///
/// Needs screen-recording permission, like anything else that can see a
/// window. Without it `SCShareableContent` returns nothing and this says so.

import AVFoundation
import AppKit
import CoreMedia
import Foundation
import ScreenCaptureKit

struct Options {
    var app = ""
    var title = ""
    var seconds = 30.0
    var out = ""
}

func parse() -> Options {
    var options = Options()
    var arguments = Array(CommandLine.arguments.dropFirst())
    while arguments.count >= 2 {
        let (flag, value) = (arguments[0], arguments[1])
        switch flag {
        case "--app": options.app = value
        case "--title": options.title = value
        case "--seconds": options.seconds = Double(value) ?? options.seconds
        case "--out": options.out = value
        default: break
        }
        arguments.removeFirst(2)
    }
    return options
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("record-window: \(message)\n".utf8))
    exit(1)
}

/// Writes frames as they arrive, and finishes the file on demand.
///
/// Every method touching `started` runs on `queue`, including the one called
/// from the capture thread. A lock would be the obvious alternative and is the
/// wrong one here: taking it from an async context is unavailable in Swift 6,
/// and `finish()` is async.
final class Writer: NSObject, SCStreamOutput {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private var started = false
    private let queue = DispatchQueue(label: "rowel.record.writer")

    init(url: URL, width: Int, height: Int) throws {
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = true
        writer.add(input)
        super.init()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, buffer.isValid, buffer.numSamples > 0 else { return }
        // A frame with no image behind it is how ScreenCaptureKit says "nothing
        // changed"; writing those makes a file whose timing is wrong.
        guard CMSampleBufferGetImageBuffer(buffer) != nil else { return }
        queue.sync {
            if !started {
                writer.startWriting()
                writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(buffer))
                started = true
            }
            if input.isReadyForMoreMediaData { input.append(buffer) }
        }
    }

    /// - Parameter done: passed false when no frame ever arrived, which is a
    ///   failure and not an empty success. A window that produced nothing is a
    ///   recording that is not there, and saying "done" about it leaves the
    ///   caller to find the missing half later — the half it went to the
    ///   trouble of recording.
    func finish(_ done: @escaping (Bool) -> Void) {
        queue.async {
            guard self.started else { return done(false) }
            self.input.markAsFinished()
            self.writer.finishWriting {
                done(self.writer.status == .completed)
            }
        }
    }
}

let options = parse()
guard !options.app.isEmpty, !options.out.isEmpty else {
    fail("usage: --app <name> --title <substring> --seconds <n> --out <file>")
}

// An NSApplication, a Task, and that application's run loop.
//
// Three things had to be true and none of them are obvious. Top-level awaits
// alongside a class conforming to an @objc protocol crash the compiler rather
// than producing a diagnostic, so the work happens in a Task. Anything that
// reads windows needs a window-server connection, and a plain command-line
// tool has none — without touching `NSApplication.shared` first the process
// aborts inside `CGS_REQUIRE_INIT` before a frame arrives. And `.accessory`
// keeps this out of the Dock and away from the foreground, because the thing
// being recorded is another application's window and stealing focus from it
// is the one thing a recorder must not do.
let application = NSApplication.shared
application.setActivationPolicy(.accessory)

Task {
    let content: SCShareableContent
    do {
        content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: false)
    } catch {
        fail("cannot see any windows — grant screen recording to whatever runs this. (\(error))")
    }

    let matches = content.windows.filter { window in
        guard window.owningApplication?.applicationName == options.app else { return false }
        guard let title = window.title, !title.isEmpty else { return false }
        // Panels and bubbles are windows too, and a browser's permission prompt
        // carries the page's address in its title — so matching on a URL picked
        // the prompt rather than the page behind it, and recorded 170x94 of a
        // dialog. Nothing worth filming is this small.
        guard window.frame.width >= 400, window.frame.height >= 300 else { return false }
        return options.title.isEmpty || title.contains(options.title)
    }

    // Exactly one, or nothing. Picking the first of several is how you record
    // the wrong one and only find out later.
    guard matches.count == 1, let window = matches.first else {
        fail(matches.isEmpty
             ? "no \(options.app) window with \(options.title.isEmpty ? "any title" : "“\(options.title)” in its title")"
             : "\(matches.count) windows match; narrow --title so exactly one does")
    }

    let scale = 2
    let width = Int(window.frame.width) * scale
    let height = Int(window.frame.height) * scale

    let configuration = SCStreamConfiguration()
    configuration.width = width
    configuration.height = height
    configuration.showsCursor = false
    configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
    configuration.queueDepth = 8

    do {
        let writer = try Writer(url: URL(fileURLWithPath: options.out), width: width, height: height)
        let stream = SCStream(
            filter: SCContentFilter(desktopIndependentWindow: window),
            configuration: configuration,
            delegate: nil)
        try stream.addStreamOutput(
            writer, type: .screen, sampleHandlerQueue: DispatchQueue(label: "rowel.record"))
        try await stream.startCapture()
        try await Task.sleep(nanoseconds: UInt64(options.seconds * 1_000_000_000))
        try? await stream.stopCapture()
        writer.finish { wrote in
            let size = ((try? FileManager.default
                .attributesOfItem(atPath: options.out)[.size]) as? Int) ?? 0
            guard wrote, size > 0 else {
                fail("the window produced no frames — nothing was written to \(options.out)")
            }
            print("recorded \(window.title ?? "window") — \(width)x\(height), \(size) bytes")
            exit(0)
        }
    } catch {
        fail("could not record: \(error)")
    }
}

application.run()
