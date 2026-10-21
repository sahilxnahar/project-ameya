import AmeyaCore
import AppKit
import Foundation
import ImageIO
import Metal
import ModelIO
import SceneKit
import SceneKit.ModelIO

/// Converts 3D models between USDZ, USD (text and binary), OBJ, STL and PLY, reads Alembic,
/// and renders a PNG preview. Model I/O does the reading and most writing; SceneKit writes
/// USDZ (Model I/O can't) and renders previews offscreen on the GPU.
///
/// The worker receives one file, so an OBJ's separate .mtl and texture images never arrive,
/// and an OBJ written here can't carry its .mtl either: its `mtllib` line is removed.
@MainActor
enum ModelConverter {
    static let previewSize = 1024

    static func convert(input: URL, to target: FileFormat, output: URL, progress: (Double) -> Void) throws -> [ConversionNote] {
        let asset = try load(input)
        progress(0.4)
        var notes: [ConversionNote] = []
        switch target {
        case .png:
            try renderPreview(asset, to: output)
        case .usdz:
            let scene = SCNScene(mdlAsset: asset)
            guard scene.write(to: output, options: nil, delegate: nil, progressHandler: nil) else {
                throw ConversionError.encodeFailed(target)
            }
            notes = [.materialsMayNotCarryOver]
        default:
            guard target.family == .model, target != .abc,
                  MDLAsset.canExportFileExtension(target.preferredExtension) else {
                throw ConversionError.unsupportedTarget(target)
            }
            do {
                try asset.export(to: output)
            } catch {
                throw ConversionError.encodeFailed(target)
            }
            if target == .obj { try removeMaterialLibrary(from: output) }
            notes = [.materialsMayNotCarryOver]
        }
        progress(1)
        return notes
    }

    /// Loads a model and checks it has geometry. Model I/O picks the reader from the extension,
    /// which the worker sets from the detected source format.
    static func load(_ url: URL) throws -> MDLAsset {
        guard MDLAsset.canImportFileExtension(url.pathExtension) else { throw ConversionError.unreadable }
        let asset = MDLAsset(url: url)
        guard vertexCount(asset) > 0 else {
            throw ConversionError.invalidData("no 3D geometry was found in it")
        }
        return asset
    }

    /// Total vertices across every mesh in the asset, including nested ones.
    static func vertexCount(_ asset: MDLAsset) -> Int {
        asset.childObjects(of: MDLMesh.self).reduce(0) { $0 + (($1 as? MDLMesh)?.vertexCount ?? 0) }
    }

    /// Model I/O writes `mtllib name.mtl` next to the OBJ; that file can't be delivered.
    private static func removeMaterialLibrary(from url: URL) throws {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let newline = UInt8(ascii: "\n")
        var kept = Data(capacity: data.count)
        for line in data.split(separator: newline, omittingEmptySubsequences: false) {
            if line.starts(with: Array("mtllib ".utf8)) { continue }
            kept.append(contentsOf: line)
            kept.append(newline)
        }
        if kept.last == newline, data.last != newline { kept.removeLast() }
        try kept.write(to: url)
    }

    // MARK: Preview

    /// Renders the model from a three-quarter view on a light grey background with soft,
    /// neutral lighting, framed to fit, as a square PNG.
    static func renderPreview(_ asset: MDLAsset, to output: URL) throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw ConversionError.mediaFailed("3D previews need a graphics processor, and none is available")
        }
        let scene = SCNScene(mdlAsset: asset)
        scene.background.contents = NSColor(white: 0.93, alpha: 1)

        let (center, radius) = scene.rootNode.boundingSphere
        let fieldOfView = 35.0
        let distance = max(Double(radius), 0.001) / sin(fieldOfView / 2 * .pi / 180) * 1.15
        let direction = SCNVector3(0.55, 0.45, 0.70) // already close to unit length
        let camera = SCNCamera()
        camera.fieldOfView = fieldOfView
        camera.zNear = distance * 0.01
        camera.zFar = distance * 10
        let cameraNode = SCNNode()
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(center.x + direction.x * distance, center.y + direction.y * distance,
                                         center.z + direction.z * distance)
        cameraNode.look(at: center)
        scene.rootNode.addChildNode(cameraNode)

        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 450
        ambient.light?.color = NSColor.white
        scene.rootNode.addChildNode(ambient)
        let key = SCNNode()
        key.light = SCNLight()
        key.light?.type = .directional
        key.light?.intensity = 750
        key.light?.color = NSColor.white
        key.position = cameraNode.position
        key.look(at: center)
        scene.rootNode.addChildNode(key)

        let renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = scene
        renderer.pointOfView = cameraNode
        let size = CGSize(width: previewSize, height: previewSize)
        let image = renderer.snapshot(atTime: 0, with: size, antialiasingMode: .multisampling4X)
        var rect = CGRect(origin: .zero, size: size)
        guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil),
              let destination = CGImageDestinationCreateWithURL(output as CFURL, FileFormat.png.typeIdentifier as CFString, 1, nil) else {
            throw ConversionError.encodeFailed(.png)
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else { throw ConversionError.encodeFailed(.png) }
    }
}
