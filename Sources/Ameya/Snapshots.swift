import AmeyaCore
import AppKit
import ImageIO
import SwiftUI

/// `Ameya --snapshots` renders the real views offscreen into PNGs for docs/screenshots, without
/// needing Screen Recording permission. Sample files are made in the sandbox's temp folder and
/// converted by the real worker; nothing touches Downloads or the user's Recent list.
@MainActor
enum Snapshots {
    static func run() async -> Bool {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Ameya Snapshots", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        let samples = folder.appendingPathComponent("samples", isDirectory: true)
        let output = folder.appendingPathComponent("output", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: samples, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        } catch {
            print("FAIL can't create \(folder.path): \(error)")
            return false
        }
        let files = makeSamples(in: samples)
        guard files.count >= 2 else {
            print("FAIL couldn't make sample files")
            return false
        }

        let store = JobStore()
        let results = ResultsModel(store: store, recentStore: RecentStore(url: folder.appendingPathComponent("recent.json")))
        func main() -> some View { MainView().environmentObject(store).environmentObject(results) }

        var ok = true
        ok = await render(main(), "empty-state", size: CGSize(width: 560, height: 560), in: folder) && ok
        ok = await render(main(), "empty-state-dark", size: CGSize(width: 560, height: 560), dark: true, in: folder) && ok
        ok = await render(OnboardingView {}, "onboarding", size: CGSize(width: 440, height: 420), in: folder) && ok
        ok = await render(SettingsView(), "settings", size: CGSize(width: 480, height: 600), in: folder) && ok

        store.add(files)
        ok = await render(main(), "files-added", size: CGSize(width: 560, height: 760), in: folder) && ok

        let jobs = store.convertNow(files, to: .jpeg, in: output)
        store.clearPending()
        for _ in 0..<600 where !jobs.allSatisfy({ $0.state.isFinished }) {
            try? await Task.sleep(for: .milliseconds(100))
        }
        ok = await render(main(), "finished-batch", size: CGSize(width: 560, height: 640), in: folder) && ok
        print(ok ? "SNAPSHOTS OK \(folder.path)" : "SNAPSHOTS FAILED \(folder.path)")
        return ok
    }

    private static func render(_ view: some View, _ name: String, size: CGSize, dark: Bool = false, in folder: URL) async -> Bool {
        // A real window paints its own background; offscreen, the root view has to.
        let root = view
            .frame(width: size.width, height: size.height, alignment: .top)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, dark ? .dark : .light)
        let hosting = NSHostingView(rootView: root)
        hosting.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        // Let thumbnails and state settle.
        try? await Task.sleep(for: .milliseconds(1200))
        hosting.layoutSubtreeIfNeeded()
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return false }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let url = folder.appendingPathComponent("\(name).png")
        guard let data = rep.representation(using: .png, properties: [:]), (try? data.write(to: url)) != nil else {
            print("FAIL \(name)")
            return false
        }
        print("PASS \(name)")
        window.contentView = nil
        return true
    }

    /// Big-ish pictures in three formats, made from the Mac's own wallpapers (or drawn).
    private static func makeSamples(in folder: URL) -> [URL] {
        let wallpaper = URL(fileURLWithPath: "/System/Library/Desktop Pictures/Mac Blue.heic")
        var image: CGImage?
        if let source = CGImageSourceCreateWithURL(wallpaper as CFURL, nil) {
            image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 2400,
            ] as CFDictionary)
        }
        if image == nil { image = drawn() }
        guard let image else { return [] }
        let samples: [(String, String)] = [("Holiday photo.heic", "public.heic"), ("Screenshot.png", "public.png"),
                                           ("Scan.tiff", "public.tiff")]
        return samples.compactMap { name, type in
            let url = folder.appendingPathComponent(name)
            guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(destination, image, nil)
            return CGImageDestinationFinalize(destination) ? url : nil
        }
    }

    private static func drawn() -> CGImage? {
        let context = CGContext(data: nil, width: 1600, height: 1000, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.setFillColor(CGColor(red: 0.9, green: 0.45, blue: 0.2, alpha: 1))
        context?.fill(CGRect(x: 0, y: 0, width: 1600, height: 1000))
        return context?.makeImage()
    }
}
