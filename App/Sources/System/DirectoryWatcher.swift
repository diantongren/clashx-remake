import Foundation

/// Coalesced change notifications for one path (file or directory) via a vnode dispatch source.
/// A directory source only fires when entries are added/removed/renamed; watch the file itself
/// for in-place edits. Atomic saves replace the file, so callers re-arm on `.rename`/`.delete`.
final class PathWatcher {
    private var source: DispatchSourceFileSystemObject?
    private var pending: Task<Void, Never>?

    init?(url: URL, debounce: Duration = .milliseconds(800), onChange: @escaping () -> Void) {
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
                                                               eventMask: [.write, .extend, .rename, .delete, .attrib],
                                                               queue: .main)
        source.setCancelHandler { close(descriptor) }
        self.source = source
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.pending?.cancel()
            self.pending = Task { @MainActor in
                try? await Task.sleep(for: debounce)
                guard !Task.isCancelled else { return }
                onChange()
            }
        }
        source.resume()
    }

    deinit {
        source?.cancel()
    }
}
