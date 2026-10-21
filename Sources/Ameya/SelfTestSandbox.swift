import AmeyaCore
import Foundation

extension SelfTest.Checker {
    /// Proves a worker, started exactly the way jobs start, can't reach files by path: not one the
    /// app itself just wrote (`ownFile`, the self-test's source), not Downloads (which the app *can*
    /// read), and it can't write beside them or start programs, while its scratch folder still works.
    /// Only reads are attempted in Downloads; a write that wrongly succeeded is undone at once.
    mutating func checkWorkerContainment(ownFile: URL) async {
        let downloads = WorkerSandbox.realDownloads
        guard WorkerSandbox.canOpen(downloads) else {
            print("FAIL sandbox setup: the app itself can't list Downloads, so the check would prove nothing")
            allPassed = false
            return
        }
        // A real file the user has there, if any, so "read" means reading actual contents.
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: downloads, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])) ?? []
        let userFile = entries.first { (try? $0.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true }
            ?? downloads.appendingPathComponent("ameya-probe-missing")
        for (label, target) in [("its own input file", ownFile), ("Downloads", userFile)] {
            do {
                let probe = try await runner.probeSandbox(target: target)
                let detail = "read \(word(probe.readFile)), list folder \(word(probe.listFolder)), "
                    + "write beside \(word(probe.writeBesideFile)), write scratch \(probe.writeScratch ? "allowed" : "DENIED"); "
                    + "a program it starts \(probe.runProgram ? "would share this sandbox" : "is refused")"
                print("\(probe.isContained ? "PASS" : "FAIL") worker can't reach \(label) by path (\(detail))")
                if !probe.isContained { allPassed = false }
            } catch {
                print("FAIL worker sandbox probe (\(label)): \(error.localizedDescription)")
                allPassed = false
            }
        }
    }

    private func word(_ allowed: Bool) -> String { allowed ? "ALLOWED" : "denied" }
}
