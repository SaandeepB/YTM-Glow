import Foundation
import Network

public struct BridgeClientID: Hashable, Sendable, CustomStringConvertible {
    public let raw: Int
    public var description: String { "client-\(raw)" }

    public init(raw: Int) {
        self.raw = raw
    }
}

public enum BridgeEvent: Sendable {
    case listening(port: UInt16)
    case failed(String)
    case connected(BridgeClientID)
    case disconnected(BridgeClientID)
    case message(BridgeClientID, InboundMessage)
}

/// WebSocket server bound to 127.0.0.1 that browser extensions push playback
/// state into. Events are delivered on the main queue.
public final class BridgeServer: @unchecked Sendable {
    public typealias EventHandler = @Sendable (BridgeEvent) -> Void

    /// Connections that send nothing (not even a ping) for this long are dropped.
    public var idleTimeout: TimeInterval = 90
    /// Connections must send a valid message this soon after connecting. Also
    /// cleans up handshakes rejected by `OriginPolicy`, which Network.framework
    /// answers with HTTP 400 but leaves open.
    public var greetingTimeout: TimeInterval = 10
    public let maxConnections = 8

    private let queue = DispatchQueue(label: "ytmglow.bridge")
    private let requestedPort: UInt16
    private let appVersion: String
    private var onEvent: EventHandler?
    private var listener: NWListener?
    private var connections: [Int: NWConnection] = [:]
    private var lastSeen: [Int: Date] = [:]
    /// Connections that have sent at least one valid message.
    private var registered: Set<Int> = []
    private var nextID = 1
    private var stopped = true
    private var wantLevels = false
    private var idleTimer: DispatchSourceTimer?

    /// - Parameter port: 0 picks a free port (used by tests).
    public init(port: UInt16 = defaultBridgePort, appVersion: String = "dev") {
        requestedPort = port
        self.appVersion = appVersion
    }

    public func start(onEvent: @escaping EventHandler) {
        queue.async {
            self.onEvent = onEvent
            self.stopped = false
            self.startListener()
        }
    }

    public func stop() {
        queue.sync {
            stopped = true
            listener?.cancel()
            listener = nil
            for connection in connections.values { connection.cancel() }
            connections.removeAll()
            lastSeen.removeAll()
            registered.removeAll()
            idleTimer?.cancel()
            idleTimer = nil
        }
    }

    /// Tells connected extensions whether to stream audio levels.
    public func setWantLevels(_ value: Bool) {
        queue.async {
            guard self.wantLevels != value else { return }
            self.wantLevels = value
            Log.bridge.info("Audio levels \(value ? "requested" : "not needed", privacy: .public)")
            self.broadcastOnQueue(.config(wantLevels: value))
        }
    }

    public func broadcast(_ message: OutboundMessage) {
        queue.async { self.broadcastOnQueue(message) }
    }

    public var connectionCount: Int { queue.sync { connections.count } }

    // MARK: - Listener

    private func startListener() {
        guard !stopped, listener == nil else { return }

        let websocket = NWProtocolWebSocket.Options()
        websocket.autoReplyPing = true
        websocket.maximumMessageSize = 256 * 1024
        websocket.setClientRequestHandler(queue) { _, headers in
            let origin = headers.first { $0.name.caseInsensitiveCompare("Origin") == .orderedSame }?.value
            let status: NWProtocolWebSocket.Response.Status = OriginPolicy.isAllowed(origin) ? .accept : .reject
            return NWProtocolWebSocket.Response(status: status, subprotocol: nil)
        }

        let parameters = NWParameters(tls: nil, tcp: NWProtocolTCP.Options())
        parameters.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)
        parameters.acceptLocalOnly = true
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(
            host: .ipv4(.loopback),
            port: NWEndpoint.Port(rawValue: requestedPort) ?? .any
        )

        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            emit(.failed("Could not open port \(requestedPort): \(error.localizedDescription)"))
            scheduleRestart()
            return
        }
        self.listener = listener

        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self, let listener else { return }
            switch state {
            case .ready:
                self.emit(.listening(port: listener.port?.rawValue ?? self.requestedPort))
            case let .failed(error):
                self.emit(.failed("Bridge stopped: \(error.localizedDescription)"))
                listener.cancel()
                if self.listener === listener { self.listener = nil }
                self.scheduleRestart()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
    }

    private func scheduleRestart() {
        queue.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.startListener()
        }
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        guard connections.count < maxConnections else {
            connection.cancel()
            return
        }
        let id = nextID
        nextID += 1
        connections[id] = connection
        lastSeen[id] = Date()

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.receive(on: connection, id: id)
                self.armIdleTimer()
                self.queue.asyncAfter(deadline: .now() + self.greetingTimeout) { [weak self] in
                    guard let self, self.connections[id] != nil, !self.registered.contains(id) else { return }
                    self.drop(id)
                }
            case .failed, .cancelled:
                self.drop(id)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func drop(_ id: Int) {
        guard let connection = connections.removeValue(forKey: id) else { return }
        lastSeen[id] = nil
        connection.cancel()
        if registered.remove(id) != nil {
            emit(.disconnected(BridgeClientID(raw: id)))
        }
    }

    private func receive(on connection: NWConnection, id: Int) {
        connection.receiveMessage { [weak self] content, context, _, error in
            guard let self else { return }
            if error != nil {
                self.drop(id)
                return
            }
            let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
            if metadata?.opcode == .close {
                self.drop(id)
                return
            }
            if let content, metadata?.opcode == .text || metadata?.opcode == .binary {
                self.lastSeen[id] = Date()
                self.handle(content, from: id, connection: connection)
            }
            if self.connections[id] != nil {
                self.receive(on: connection, id: id)
            }
        }
    }

    private func handle(_ data: Data, from id: Int, connection: NWConnection) {
        guard let message = try? MessageDecoder.decode(data) else { return }
        if registered.insert(id).inserted {
            emit(.connected(BridgeClientID(raw: id)))
        }
        switch message {
        case .hello:
            send(.welcome(appVersion: appVersion, wantLevels: wantLevels), on: connection)
        case .ping:
            send(.pong, on: connection)
        default:
            break
        }
        emit(.message(BridgeClientID(raw: id), message))
    }

    private func send(_ message: OutboundMessage, on connection: NWConnection) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "ytmglow", metadata: [metadata])
        connection.send(content: message.encoded(), contentContext: context, isComplete: true, completion: .idempotent)
    }

    private func broadcastOnQueue(_ message: OutboundMessage) {
        for connection in connections.values { send(message, on: connection) }
    }

    // MARK: - Idle sweep

    private func armIdleTimer() {
        guard idleTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let interval = max(1, idleTimeout / 3)
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .seconds(1))
        timer.setEventHandler { [weak self] in self?.sweepIdle() }
        idleTimer = timer
        timer.resume()
    }

    private func sweepIdle() {
        let cutoff = Date().addingTimeInterval(-idleTimeout)
        for (id, seen) in lastSeen where seen < cutoff { drop(id) }
        if connections.isEmpty {
            idleTimer?.cancel()
            idleTimer = nil
        }
    }

    private func emit(_ event: BridgeEvent) {
        guard let onEvent else { return }
        DispatchQueue.main.async { onEvent(event) }
    }
}
