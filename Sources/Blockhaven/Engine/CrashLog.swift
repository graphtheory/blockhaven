#if os(Windows)
import Foundation
import WinSDK

/// Where a Windows player's game says what went wrong.
///
/// The release exe is a GUI program, so nothing it writes to stderr — a
/// Swift runtime error, a failed shader, the OpenGL version — goes
/// anywhere, and a crash is a window that silently closes. Unless something
/// is already listening (a console, or the CI checks' redirect), this sends
/// stdout and stderr to `%LOCALAPPDATA%\Blockhaven\last-run.log`, and
/// records the exception that ends the process if one does.
enum CrashLog {
    nonisolated(unsafe) private static var handle: HANDLE?

    static var fileURL: URL {
        let local = ProcessInfo.processInfo.environment["LOCALAPPDATA"]
            ?? NSTemporaryDirectory()
        return URL(fileURLWithPath: local, isDirectory: true)
            .appendingPathComponent("Blockhaven", isDirectory: true)
            .appendingPathComponent("last-run.log")
    }

    static func install() {
        if let current = GetStdHandle(STD_ERROR_HANDLE), current != INVALID_HANDLE_VALUE {
            return
        }
        let url = fileURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let path = url.withUnsafeFileSystemRepresentation { String(cString: $0!) }
        let file = path.withCString(encodedAs: UTF16.self) {
            CreateFileW($0, DWORD(0x4000_0000) /* GENERIC_WRITE */, DWORD(FILE_SHARE_READ), nil,
                        DWORD(CREATE_ALWAYS), DWORD(FILE_ATTRIBUTE_NORMAL), nil)
        }
        guard let file, file != INVALID_HANDLE_VALUE else { return }
        handle = file
        SetStdHandle(STD_ERROR_HANDLE, file)
        SetStdHandle(STD_OUTPUT_HANDLE, file)
        // The C runtime's own stdout and stderr, which the Swift runtime
        // reports a fatal error through, are file descriptors 1 and 2.
        let descriptor = _open_osfhandle(intptr_t(Int(bitPattern: UnsafeRawPointer(file))), 0)
        if descriptor >= 0 {
            _ = _dup2(descriptor, 1)
            _ = _dup2(descriptor, 2)
        }
        // Room for the filter below to run even when the stack is what ran out.
        var reserve: ULONG = 64 * 1024
        _ = SetThreadStackGuarantee(&reserve)
        _ = SetUnhandledExceptionFilter { pointers in
            if let record = pointers?.pointee.ExceptionRecord?.pointee {
                let base = UInt(bitPattern: UnsafeRawPointer(GetModuleHandleW(nil)))
                let address = UInt(bitPattern: record.ExceptionAddress)
                CrashLog.write("[crash] exception 0x\(String(record.ExceptionCode, radix: 16)) at Blockhaven.exe+0x\(String(address &- base, radix: 16)) (address 0x\(String(address, radix: 16)))\n")
            }
            return EXCEPTION_CONTINUE_SEARCH
        }
        write("[log] Blockhaven started from \(CommandLine.arguments.first ?? "?")\n")
    }

    static func write(_ text: String) {
        write(Data(text.utf8))
    }

    /// Appends to the log; false when there is no log, so the caller can
    /// try somewhere else.
    @discardableResult
    static func write(_ data: Data) -> Bool {
        guard let handle else { return false }
        var bytes = [UInt8](data)
        var written: DWORD = 0
        _ = WriteFile(handle, &bytes, DWORD(bytes.count), &written, nil)
        return true
    }
}
#endif
