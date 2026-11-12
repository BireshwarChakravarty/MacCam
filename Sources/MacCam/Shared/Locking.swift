import Foundation

extension NSLock {
    /// Runs `body` while holding the lock.
    @discardableResult
    func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
