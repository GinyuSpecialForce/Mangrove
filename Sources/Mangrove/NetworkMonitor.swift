import Foundation
import Network

/// Watches whether the Mac has a usable network path, so pending work can be
/// pushed the moment the connection returns.
///
/// This is only a hint: a path can be "satisfied" while Overleaf itself is
/// unreachable (captive portal, DNS trouble, the site being down), so request
/// failures are still classified on their own.
@MainActor
final class NetworkMonitor {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.mangrovedesktop.network")
    private(set) var isOnline = true
    var onChange: ((Bool) -> Void)?

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in
                self?.apply(online)
            }
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }

    private func apply(_ online: Bool) {
        guard online != isOnline else { return }
        isOnline = online
        onChange?(online)
    }
}
