import CoreServices
import Foundation

/// Thin FSEvents wrapper: fires `onChange` (on a background queue) when
/// anything under `path` changes — working tree edits, .gitignore edits,
/// and .git internals (commits/checkouts made from a terminal).
final class FSWatcher {
    private var stream: FSEventStreamRef?
    private let onChange: () -> Void

    init?(path: String, onChange: @escaping () -> Void) {
        self.onChange = onChange

        var context = FSEventStreamContext()
        context.info = Unmanaged.passUnretained(self).toOpaque()

        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<FSWatcher>.fromOpaque(info).takeUnretainedValue().onChange()
        }

        guard let stream = FSEventStreamCreate(
            nil,
            callback,
            &context,
            [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.3, // coalesce bursts at the FSEvents layer
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer)
        ) else { return nil }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.global(qos: .utility))
        FSEventStreamStart(stream)
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}
