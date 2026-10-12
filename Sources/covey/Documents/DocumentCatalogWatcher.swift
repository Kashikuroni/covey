import Foundation
import CoreServices

/// A recursive, debounced filesystem observer. Stream context owns its callback
/// independently of the Swift token, so queued events cannot dereference it after cancellation.
final class DocumentCatalogWatchToken: @unchecked Sendable {
    private final class Callback: @unchecked Sendable {
        let queue: DispatchQueue
        let onChange: @Sendable () -> Void
        var pending: DispatchWorkItem?
        var cancelled = false
        init(queue: DispatchQueue, onChange: @escaping @Sendable () -> Void) { self.queue = queue; self.onChange = onChange }
        func changed() {
            guard !cancelled else { return }
            pending?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, !self.cancelled else { return }
                self.onChange()
            }
            pending = work
            queue.asyncAfter(deadline:.now() + 0.25,execute:work)
        }
    }
    private let queue = DispatchQueue(label:"covey.documents.events")
    private let queueKey = DispatchSpecificKey<Bool>()
    private var stream: FSEventStreamRef?
    private let callback: Callback
    private let lock = NSLock()
    init(root: String, onChange: @escaping @Sendable () -> Void) {
        callback = Callback(queue:queue,onChange:onChange)
        queue.setSpecific(key:queueKey,value:true)
        var context = FSEventStreamContext(version:0,info:Unmanaged.passUnretained(callback).toOpaque(),retain:{ info in
            guard let info else { return nil }
            _ = Unmanaged<Callback>.fromOpaque(info).retain()
            return UnsafeRawPointer(info)
        },release:{ info in
            if let info { Unmanaged<Callback>.fromOpaque(info).release() }
        },copyDescription:nil)
        stream = FSEventStreamCreate(nil,{ _, info, _, _, _, _ in
            if let info { Unmanaged<Callback>.fromOpaque(info).takeUnretainedValue().changed() }
        },&context,[root] as CFArray,FSEventStreamEventId(kFSEventStreamEventIdSinceNow),0.1,
        FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagNoDefer))
        if let stream {
            FSEventStreamSetDispatchQueue(stream,queue)
            if !FSEventStreamStart(stream) { FSEventStreamInvalidate(stream); FSEventStreamRelease(stream); self.stream = nil }
        }
    }
    func cancel() {
        lock.lock()
        let old = stream
        stream = nil
        lock.unlock()
        guard let old else { return }
        let cleanup = { self.callback.cancelled = true; self.callback.pending?.cancel(); self.callback.pending = nil }
        if DispatchQueue.getSpecific(key:queueKey) == true { cleanup() } else { queue.sync(execute:cleanup) }
        FSEventStreamStop(old)
        FSEventStreamInvalidate(old)
        FSEventStreamRelease(old)
    }
    deinit { cancel() }
}
protocol DocumentCatalogWatching: Sendable {
    func observe(root: String, onChange: @escaping @Sendable () -> Void) -> DocumentCatalogWatchToken
}
struct DocumentCatalogWatcher: DocumentCatalogWatching {
    func observe(root: String, onChange: @escaping @Sendable () -> Void) -> DocumentCatalogWatchToken {
        DocumentCatalogWatchToken(root:root,onChange:onChange)
    }
}
