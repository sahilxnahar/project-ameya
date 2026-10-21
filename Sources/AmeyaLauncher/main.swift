import AmeyaCore
import Foundation

// The XPC service that starts workers. Its sandbox has no file entitlements, and workers inherit
// it instead of the app's, so a worker can't open Downloads, the output folder or anything the
// user dropped; it only has the three descriptors the app hands over (see AmeyaLauncherXPC).

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    let worker: URL

    init(worker: URL) {
        self.worker = worker
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        let service = LauncherService(worker: worker)
        connection.exportedInterface = NSXPCInterface(with: AmeyaLauncherXPC.self)
        connection.exportedObject = service
        // If the app quits or crashes, nothing it started keeps running.
        connection.invalidationHandler = { service.terminateAll() }
        connection.interruptionHandler = { service.terminateAll() }
        connection.resume()
        return true
    }
}

/// Removes scratch folders of workers that were killed, now and every hour.
func sweepScratchFolders() {
    LeftoverSweeper.removeScratchFolders(in: FileManager.default.temporaryDirectory)
}

guard let worker = Bundle.main.url(forAuxiliaryExecutable: "AmeyaWorker") else {
    fatalError("AmeyaWorker is missing from the launcher bundle")
}
sweepScratchFolders()
let sweeper = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
sweeper.schedule(deadline: .now() + 3600, repeating: 3600)
sweeper.setEventHandler(handler: sweepScratchFolders)
sweeper.resume()

let delegate = ListenerDelegate(worker: worker)
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
