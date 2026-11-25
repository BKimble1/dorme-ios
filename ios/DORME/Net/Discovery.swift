import Foundation
import Network

/// Finds robots on the local network through Bonjour (_dorme._tcp, advertised by Avahi on the Pi) and
/// resolves each to an IPv4 address the HTTP client can use. Also notices when iOS has denied the app
/// Local Network access, which otherwise looks like "can't reach" with no reason.
@MainActor
@Observable
final class Discovery {
    private(set) var hosts: [String] = []
    private(set) var denied = false
    private(set) var browsing = false

    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private var resolvers: [NWConnection] = []

    func start() {
        guard browser == nil else { return }
        let params = NWParameters()
        params.includePeerToPeer = false
        let b = NWBrowser(for: .bonjour(type: "_dorme._tcp", domain: nil), using: params)
        b.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in self?.browserState(state) }
        }
        b.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in self?.resolve(results) }
        }
        b.start(queue: .main)
        browser = b
        browsing = true
    }

    func stop() {
        browser?.cancel()
        browser = nil
        browsing = false
        resolvers.forEach { $0.cancel() }
        resolvers = []
    }

    func restart() {
        stop()
        hosts = []
        start()
    }

    private func browserState(_ state: NWBrowser.State) {
        switch state {
        case .waiting(let error), .failed(let error):
            // kDNSServiceErr_PolicyDenied (-65570): the user has not allowed Local Network access.
            if case .dns(let code) = error, code == -65570 { denied = true }
        case .ready:
            denied = false
        default:
            break
        }
    }

    private func resolve(_ results: Set<NWBrowser.Result>) {
        for result in results {
            let params = NWParameters.tcp
            if let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
                ip.version = .v4
            }
            let connection = NWConnection(to: result.endpoint, using: params)
            connection.stateUpdateHandler = { [weak self, weak connection] state in
                switch state {
                case .ready:
                    if case .hostPort(let host, _)? = connection?.currentPath?.remoteEndpoint {
                        var text: String
                        switch host {
                        case .ipv4(let a): text = "\(a)"
                        case .ipv6(let a): text = "\(a)"
                        case .name(let n, _): text = n
                        @unknown default: text = "\(host)"
                        }
                        if let pct = text.firstIndex(of: "%") { text = String(text[..<pct]) }
                        Task { @MainActor in self?.add(text) }
                    }
                    connection?.cancel()
                case .failed, .waiting:
                    connection?.cancel()
                default:
                    break
                }
            }
            connection.start(queue: .main)
            resolvers.append(connection)
        }
    }

    private func add(_ host: String) {
        if !hosts.contains(host) { hosts.insert(host, at: 0) }
    }
}
