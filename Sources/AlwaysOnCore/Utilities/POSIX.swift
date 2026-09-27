#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Thin wrappers over POSIX calls whose Swift spelling differs between Darwin and Glibc.
enum POSIX {
    static var streamSocketType: Int32 {
        #if canImport(Darwin)
        return SOCK_STREAM
        #else
        return Int32(SOCK_STREAM.rawValue)
        #endif
    }

    static func closeFD(_ fd: Int32) {
        _ = close(fd)
    }

    static var errnoDescription: String {
        String(cString: strerror(errno))
    }
}
