import Foundation
import Darwin
import CoveyKit

final class DocumentWatchToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancellation: (() -> Void)?
    init(cancel: @escaping () -> Void) { cancellation = cancel }
    func cancel() {
        lock.lock(); let action = cancellation; cancellation = nil; lock.unlock()
        action?()
    }
    deinit { cancel() }
}
protocol DocumentWatching: Sendable {
    func watch(path: String, context: DocumentContext, onChange: @escaping @Sendable () -> Void) -> DocumentWatchToken
}
struct DocumentFileWatcher: DocumentWatching {
    func watch(path: String, context: DocumentContext, onChange: @escaping @Sendable () -> Void) -> DocumentWatchToken {
        let observation = FileObservation(path:path,context:context,onChange:onChange)
        observation.start()
        return .init { observation.stop() }
    }
}
private final class FileObservation: @unchecked Sendable {
    private let queue = DispatchQueue(label:"covey.documents.file")
    private let queueKey = DispatchSpecificKey<Bool>()
    private let path: String
    private let context: DocumentContext
    private let onChange: @Sendable () -> Void
    private var file: DispatchSourceFileSystemObject?
    private var parent: DispatchSourceFileSystemObject?
    private var retry: DispatchSourceTimer?
    private var pending: DispatchWorkItem?
    private var stopped = false
    init(path: String, context: DocumentContext, onChange: @escaping @Sendable () -> Void) {
        self.path = path; self.context = context; self.onChange = onChange
        queue.setSpecific(key:queueKey,value:true)
    }
    func start() { queue.sync { attach() } }
    private func source(_ url: URL, directory: Bool) -> DispatchSourceFileSystemObject? {
        let fd = Darwin.open(url.path,O_EVTONLY | O_NOFOLLOW)
        guard fd >= 0 else { return nil }
        var info = stat()
        guard fstat(fd,&info) == 0, info.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG) else { Darwin.close(fd); return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor:fd,eventMask:[.write,.extend,.attrib,.rename,.delete,.revoke],queue:queue)
        source.setEventHandler { [weak self, weak source] in
            guard let self, !self.stopped else { return }
            let removed = source?.data.intersection([.rename,.delete,.revoke]).isEmpty == false
            if removed { self.file?.cancel(); self.file = nil; self.parent?.cancel(); self.parent = nil }
            else if directory { self.file?.cancel(); self.file = nil }
            self.attach()
            self.changed()
        }
        source.setCancelHandler { Darwin.close(fd) }
        source.resume()
        return source
    }
    private func attach() {
        guard !stopped, let url = try? DocumentLinkResolver.fileURL(path:path,context:context) else { scheduleRetry(); return }
        if parent == nil { parent = source(url.deletingLastPathComponent(),directory:true) }
        if file == nil { file = source(url,directory:false) }
        if parent == nil { scheduleRetry() }
        else { retry?.cancel(); retry = nil }
    }
    private func scheduleRetry() {
        guard !stopped, retry == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue:queue)
        timer.schedule(deadline:.now() + 0.5,repeating:0.5,leeway:.milliseconds(100))
        timer.setEventHandler { [weak self] in
            guard let self, !self.stopped else { return }
            self.attach()
            if self.parent != nil { self.changed() }
        }
        retry = timer; timer.resume()
    }
    private func changed() {
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in guard let self, !self.stopped else { return }; self.onChange() }
        pending = item; queue.asyncAfter(deadline:.now() + 0.25,execute:item)
    }
    func stop() {
        let action = {
            self.stopped = true; self.pending?.cancel(); self.pending = nil
            self.file?.cancel(); self.file = nil; self.parent?.cancel(); self.parent = nil
            self.retry?.cancel(); self.retry = nil
        }
        if DispatchQueue.getSpecific(key:queueKey) == true { action() } else { queue.sync(execute:action) }
    }
}
