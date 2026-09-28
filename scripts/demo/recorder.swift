// Records one app's main window to an H.264 MP4 with ScreenCaptureKit. Only that window
// is captured, even when other windows cover it, and without the cursor.
//
//   recorder --pid 1234 --out demo.mp4 [--fps 30] [--log recorder.log]
//
// Recording runs until the process gets SIGINT or SIGTERM, then the file is finished.
// record.sh wraps it in a small signed app ("Hyprmux Demo Recorder") and starts it with
// `open`, so it holds its own Screen Recording permission instead of borrowing the
// terminal's.
import AppKit
import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

func fail(_ message: String) -> Never {
    FileHandle.standardError.write("recorder: \(message)\n".data(using: .utf8)!)
    exit(1)
}

var pid: pid_t = 0
var out = ""
var fps = 30
var args = CommandLine.arguments.dropFirst().makeIterator()
while let a = args.next() {
    switch a {
    case "--pid": pid = pid_t(args.next() ?? "") ?? 0
    case "--out": out = args.next() ?? ""
    case "--fps": fps = Int(args.next() ?? "") ?? 30
    case "--log":
        // Started with `open`, there's no terminal to print to.
        let path = args.next() ?? "/dev/null"
        freopen(path, "a", stdout)
        freopen(path, "a", stderr)
        setvbuf(stdout, nil, _IOLBF, 0)
    default: fail("unknown argument \(a)")
    }
}
guard pid > 0, !out.isEmpty else { fail("usage: recorder --pid PID --out FILE.mp4 [--fps N]") }

final class Recorder: NSObject, SCStreamOutput, SCStreamDelegate {
    let writer: AVAssetWriter
    let input: AVAssetWriterInput
    var stream: SCStream?
    var started = false
    let queue = DispatchQueue(label: "recorder")

    init(url: URL, width: Int, height: Int) throws {
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: width * height * 6],
        ])
        input.expectsMediaDataInRealTime = true
        writer.add(input)
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sb.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete else { return }
        if !started {
            writer.startWriting()
            writer.startSession(atSourceTime: sb.presentationTimeStamp)
            started = true
        }
        if input.isReadyForMoreMediaData { input.append(sb) }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) { fail("stream stopped: \(error.localizedDescription)") }

    func finish() async {
        try? await stream?.stopCapture()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            queue.async {
                guard self.started else { c.resume(); return }
                self.input.markAsFinished()
                self.writer.finishWriting { c.resume() }
            }
        }
    }
}

var recorder: Recorder?

// ScreenCaptureKit's streams need a window-server connection, which NSApplication sets up.
_ = NSApplication.shared
NSApp.setActivationPolicy(.prohibited)

Task {
    let content: SCShareableContent
    do {
        content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
    } catch {
        fail("no Screen Recording permission (\(error.localizedDescription))")
    }
    // Any level: record.sh floats the demo window above the rest.
    let windows = content.windows.filter { $0.owningApplication?.processID == pid && $0.frame.width > 200 && $0.frame.height > 200 }
    guard let window = windows.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else {
        fail("no window for pid \(pid)")
    }
    let scale = 2
    let width = Int(window.frame.width) * scale, height = Int(window.frame.height) * scale
    let config = SCStreamConfiguration()
    config.width = width
    config.height = height
    config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
    config.showsCursor = false
    config.queueDepth = 6
    do {
        let r = try Recorder(url: URL(fileURLWithPath: out), width: width, height: height)
        let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: window), configuration: config, delegate: r)
        try stream.addStreamOutput(r, type: .screen, sampleHandlerQueue: r.queue)
        try await stream.startCapture()
        r.stream = stream
        recorder = r
        print("recording \(width)x\(height) @\(fps)fps -> \(out)")
    } catch {
        fail("can't start: \(error.localizedDescription)")
    }
}

var signalSources: [DispatchSourceSignal] = []
for sig in [SIGINT, SIGTERM] {
    signal(sig, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    src.setEventHandler {
        Task {
            await recorder?.finish()
            print("saved \(out)")
            exit(0)
        }
    }
    src.resume()
    signalSources.append(src)
}
dispatchMain()
