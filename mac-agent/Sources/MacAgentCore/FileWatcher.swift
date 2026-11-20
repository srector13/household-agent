import Foundation

/// Watches chat.db and chat.db-wal for writes and calls `onChange`. On platforms without
/// kqueue-backed file sources (Linux, used only for tests) it does nothing and the agent relies
/// on its safety poll.
public final class FileWatcher: @unchecked Sendable {
    private let paths: [String]
    private let onChange: @Sendable () -> Void
    private let queue = DispatchQueue(label: "household.filewatcher")
    #if canImport(Darwin)
    private var sources: [DispatchSourceFileSystemObject] = []
    #endif

    public init(paths: [String], onChange: @escaping @Sendable () -> Void) {
        self.paths = paths
        self.onChange = onChange
    }

    /// (Re)creates the watchers. The WAL file is recreated on checkpoint, so `.delete`/`.rename`
    /// events trigger a re-arm.
    public func start() {
        #if canImport(Darwin)
        queue.async { [self] in self.arm() }
        #endif
    }

    public func stop() {
        #if canImport(Darwin)
        queue.async { [self] in
            self.sources.forEach { $0.cancel() }
            self.sources.removeAll()
        }
        #endif
    }

    #if canImport(Darwin)
    private func arm() {
        sources.forEach { $0.cancel() }
        sources.removeAll()
        for path in paths {
            let fd = open(path, O_EVTONLY)
            guard fd >= 0 else {
                Log.debug("watcher: cannot open \(path) (errno \(errno))")
                continue
            }
            let src = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: [.write, .extend, .delete, .rename, .link],
                queue: queue
            )
            src.setEventHandler { [weak self, weak src] in
                guard let self, let src else { return }
                let flags = src.data
                self.onChange()
                if flags.contains(.delete) || flags.contains(.rename) {
                    // File replaced (e.g. WAL reset); re-arm shortly.
                    self.queue.asyncAfter(deadline: .now() + 1) { self.arm() }
                }
            }
            src.setCancelHandler { close(fd) }
            src.resume()
            sources.append(src)
        }
    }
    #endif
}
