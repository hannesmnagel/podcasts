import Foundation
import Network

final class NetworkMonitor: @unchecked Sendable {
    static let shared = NetworkMonitor()

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "NetworkMonitor")
    private let lock = NSLock()
    private var _isConnected = true
    private var _connectionType: NWInterface.InterfaceType?

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let connectionType = path.availableInterfaces.first(where: { path.usesInterfaceType($0.type) })?.type
            lock.lock()
            _isConnected = path.status == .satisfied
            _connectionType = connectionType
            lock.unlock()
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }

    var isConnected: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isConnected
    }

    var connectionType: NWInterface.InterfaceType? {
        lock.lock()
        defer { lock.unlock() }
        return _connectionType
    }

    var isOffline: Bool {
        !isConnected
    }
}
