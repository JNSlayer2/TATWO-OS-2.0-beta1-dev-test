import Darwin

enum ComputerUseConnection {
    static func isAlive(_ fd: Int32) -> Bool {
        // On Darwin, polling reads reports HUP for the normal request
        // half-close. POLLOUT distinguishes it from a disconnected receiver.
        var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        return poll(&descriptor, 1, 0) >= 0
            && (descriptor.revents & Int16(POLLHUP | POLLERR | POLLNVAL)) == 0
    }
}
