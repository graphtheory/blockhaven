import Foundation
#if os(Windows)
import WinSDK
#endif

/// Seconds on a clock that only ever goes forward — for measuring, never
/// for dates. `CFAbsoluteTimeGetCurrent` is CoreFoundation's and does not
/// exist on Windows.
@inline(__always)
func monotonicSeconds() -> Double {
    Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
}

/// `setenv`, which Windows spells `_putenv_s` and has no "keep an existing
/// value" switch for.
func setEnvironment(_ name: String, _ value: String, overwrite: Bool) {
    #if os(Windows)
    if !overwrite, ProcessInfo.processInfo.environment[name] != nil { return }
    _ = _putenv_s(name, value)
    #else
    setenv(name, value, overwrite ? 1 : 0)
    #endif
}

/// Moves `source` over `destination` in one step, so a reader never finds
/// half a file. `FileManager.replaceItemAt` is that on the Mac and not
/// implemented on Windows, where `MoveFileExW` is the same promise.
func replaceFile(at destination: URL, with source: URL) throws {
    #if os(Windows)
    // The file-system representation is the native path — drive letter,
    // backslashes — which `URL.path` does not promise on Windows.
    func native(_ url: URL) -> String {
        url.withUnsafeFileSystemRepresentation { String(cString: $0!) }
    }
    let moved = native(source).withCString(encodedAs: UTF16.self) { from in
        native(destination).withCString(encodedAs: UTF16.self) { to in
            MoveFileExW(from, to, DWORD(MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH))
        }
    }
    if !moved {
        throw CocoaError(.fileWriteUnknown, userInfo: [
            NSFilePathErrorKey: destination.path,
            "WindowsError": GetLastError(),
        ])
    }
    #else
    _ = try FileManager.default.replaceItemAt(destination, withItemAt: source)
    #endif
}

/// Whether a path names one place regardless of the working directory —
/// `/…` on the Mac, `C:\…`, `C:/…` or a `\\server\share` on Windows.
func isAbsolutePath(_ path: String) -> Bool {
    #if os(Windows)
    let characters = Array(path)
    if characters.count >= 3, characters[0].isLetter, characters[1] == ":",
       characters[2] == "\\" || characters[2] == "/" {
        return true
    }
    return path.hasPrefix("\\\\") || path.hasPrefix("//")
    #else
    return path.hasPrefix("/")
    #endif
}

/// The running program's own file. `CommandLine.arguments[0]` is only what
/// the launcher typed, which a Windows shortcut need not spell as a full
/// path; the module's file name is always one.
func executableURL() -> URL {
    #if os(Windows)
    var buffer = [WCHAR](repeating: 0, count: 32_768)
    let length = GetModuleFileNameW(nil, &buffer, DWORD(buffer.count))
    if length > 0 {
        return URL(fileURLWithPath: String(decoding: buffer[..<Int(length)], as: UTF16.self))
    }
    #endif
    return URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0]).resolvingSymlinksInPath()
}

/// Writes to stderr, and shrugs if that fails. `FileHandle.write(_:)` traps
/// on a failed write, and a Windows GUI program's stderr is no file at all:
/// a player's game died on the very first status line it printed. On
/// Windows this lands in `CrashLog`'s file when that is open.
enum StandardError {
    static func write(_ data: Data) {
        #if os(Windows)
        if CrashLog.write(data) { return }
        guard let handle = GetStdHandle(STD_ERROR_HANDLE), handle != INVALID_HANDLE_VALUE else { return }
        var bytes = [UInt8](data)
        var written: DWORD = 0
        _ = WriteFile(handle, &bytes, DWORD(bytes.count), &written, nil)
        #else
        try? FileHandle.standardError.write(contentsOf: data)
        #endif
    }
}
