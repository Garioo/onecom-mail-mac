// Self-updating: the app remembers the folder it was built from. When the source files there change
// (for example when Claude puts a new version in place), it offers "Update Ready". One click
// rebuilds the app with build.sh, swaps it in and relaunches it. No Terminal needed.

import AppKit

@MainActor
final class Updater {
    let sourceFolder: URL?
    private let buildStamp: TimeInterval

    private(set) var updateAvailable = false
    private(set) var isBuilding = false

    /// Called whenever `updateAvailable` or `isBuilding` changes.
    var onChange: (() -> Void)?
    /// Called once each time a new update is detected.
    var onUpdateFound: (() -> Void)?
    /// Called with the build log when an update fails to build.
    var onFailure: ((String) -> Void)?

    private var timer: Timer?
    private var process: Process?
    private var log = ""
    private var quitting = false

    init() {
        let info = Bundle.main.infoDictionary ?? [:]
        if let path = info["OneMailSourceFolder"] as? String,
           FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent("build.sh")) {
            sourceFolder = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            sourceFolder = nil
        }
        buildStamp = (info["OneMailBuildStamp"] as? String).flatMap { Double($0) } ?? 0
    }

    func start() {
        guard sourceFolder != nil else { return }
        check()
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.check() }
        }
    }

    /// Looks for source files newer than this build.
    func check() {
        guard let folder = sourceFolder, !isBuilding else { return }
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: folder.path) else { return }
        var newest: TimeInterval = 0
        for name in names where name.hasSuffix(".swift") || name == "build.sh" {
            let path = folder.appendingPathComponent(name).path
            if let date = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date {
                newest = max(newest, date.timeIntervalSince1970)
            }
        }
        let available = newest > buildStamp + 1
        if available != updateAvailable {
            updateAvailable = available
            onChange?()
            if available { onUpdateFound?() }
        }
    }

    /// Rebuilds from the source folder. If the build succeeds, the app quits and the
    /// build script installs the new version in its place and opens it.
    func install() {
        guard let folder = sourceFolder, !isBuilding else { return }
        isBuilding = true
        quitting = false
        log = ""
        onChange?()

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [folder.appendingPathComponent("build.sh").path, "--update",
                       String(ProcessInfo.processInfo.processIdentifier), Bundle.main.bundlePath]
        p.currentDirectoryURL = folder
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin"
        p.environment = env

        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let text = String(decoding: data, as: UTF8.self)
            Task { @MainActor in self?.received(text) }
        }
        p.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            Task { @MainActor in self?.finished(status) }
        }

        do {
            try p.run()
            process = p
        } catch {
            isBuilding = false
            onChange?()
            onFailure?("Couldn't start the build: \(error.localizedDescription)")
        }
    }

    private func received(_ text: String) {
        log += text
        if !quitting && log.contains("BUILD_OK") {
            // The new version is built; quit so the script can swap it in and relaunch.
            quitting = true
            NSApp.terminate(nil)
        }
    }

    private func finished(_ status: Int32) {
        if quitting { return }
        isBuilding = false
        onChange?()
        if status != 0 {
            onFailure?(log.isEmpty ? "The build stopped with code \(status)." : log)
        }
    }
}
