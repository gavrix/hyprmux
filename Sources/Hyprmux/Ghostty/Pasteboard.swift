import AppKit
import UniformTypeIdentifiers

/// What pasting or dropping a pasteboard into a terminal inserts. Follows Ghostty's
/// macOS app (NSPasteboard+Extension.swift), plus images:
/// - files: their paths, shell-escaped, space-separated (a Finder copy, a dragged file);
/// - else any string;
/// - else image data (a screenshot copied to the clipboard, an image dragged from a
///   browser): written to a temporary PNG, and its path. Agents like pi turn a pasted
///   image path into an attachment, the same as a dragged file.
enum TerminalPasteboard {
    static let dropTypes: [NSPasteboard.PasteboardType] = [.fileURL, .URL, .string, .png, .tiff]

    static func contents(_ pb: NSPasteboard, imagesAsFiles: Bool = true) -> String? {
        let items = pb.pasteboardItems ?? []
        var parts: [String] = []
        for item in items {
            if let plist = item.propertyList(forType: .fileURL),
               let url = NSURL(pasteboardPropertyList: plist, ofType: .fileURL) as URL?, url.isFileURL {
                parts.append(escape(url.path))
            } else if let s = item.string(forType: .string) {
                parts.append(s)
            } else if let u = item.string(forType: .URL) {
                parts.append(u)
            }
        }
        if !parts.isEmpty { return parts.joined(separator: " ") }
        guard imagesAsFiles, let path = writeImage(pb) else { return nil }
        return escape(path)
    }

    /// Saves the pasteboard's image as PNG in the temporary directory.
    private static func writeImage(_ pb: NSPasteboard) -> String? {
        let data: Data
        if let png = pb.data(forType: .png) {
            data = png
        } else if let image = NSImage(pasteboard: pb), let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
            data = png
        } else {
            return nil
        }
        let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("hyprmux-paste")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = (dir as NSString).appendingPathComponent("image-\(UUID().uuidString.prefix(8)).png")
        do {
            try data.write(to: URL(fileURLWithPath: path))
            return path
        } catch {
            log.error("paste: can't write image: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Backslash-escapes shell-sensitive characters, like Ghostty.Shell.escape.
    static func escape(_ s: String) -> String {
        var out = ""
        for c in s {
            if "\\ ()[]{}<>\"'`!#$&;|*?\t".contains(c) { out.append("\\") }
            out.append(c)
        }
        return out
    }
}
