#if canImport(CSDL3)
import Foundation
import CSDL3

/// The system's own "choose a folder" dialog, through SDL.
///
/// SDL answers on a callback that may arrive on another thread and cannot
/// capture anything, so the answer is left in a locked mailbox and picked
/// up by the menu on its next frame.
enum SDLFolderPicker {
    enum Answer {
        case chosen(URL)
        case cancelled
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var mailbox: Answer?
    nonisolated(unsafe) private(set) static var isOpen = false

    static func open(window: OpaquePointer, startingAt start: URL?) {
        guard !isOpen else { return }
        isOpen = true
        let callback: SDL_DialogFileCallback = { _, files, _ in
            var answer = Answer.cancelled
            if let files, let first = files.pointee {
                answer = .chosen(URL(fileURLWithPath: String(cString: first), isDirectory: true))
            }
            SDLFolderPicker.lock.lock()
            SDLFolderPicker.mailbox = answer
            SDLFolderPicker.lock.unlock()
        }
        if let start {
            start.withUnsafeFileSystemRepresentation { path in
                SDL_ShowOpenFolderDialog(callback, nil, window, path, false)
            }
        } else {
            SDL_ShowOpenFolderDialog(callback, nil, window, nil, false)
        }
    }

    /// The answer, once, if it has arrived.
    static func take() -> Answer? {
        lock.lock()
        defer { lock.unlock() }
        guard let answer = mailbox else { return nil }
        mailbox = nil
        isOpen = false
        return answer
    }
}
#endif
