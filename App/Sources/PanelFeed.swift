import ClassicUI
import Foundation
import Network
import Observation
import PlayerCore
import SkinKit

/// A local WebSocket feed of the main window's display, for screens outside
/// the app (another program shows it on a panel, say): ws://127.0.0.1:24248
/// by default, this Mac only, off unless turned on in Preferences.
///
/// Binary messages are parts of the main window as it is drawn, full size
/// even when it is shaded or hidden (`PanelFeedFormat`): the display (play
/// indicator, time, visualizer; from a visualizer of the feed's own) and the
/// scrolling title. Each is sent when it changes, checked 60 times a second:
/// up to 60 a second while playing, a blink a second when paused; a client
/// gets both on connecting.
///
/// Text messages are JSON. "status" on connecting and whenever the state,
/// the track (gapless changes too), the position (a seek) or a visualizer
/// option changes (`visMode`, and all of them in `visualizer`); `position`
/// is the seconds into the track at `sentAt` (Unix time), the client counts
/// on from there. "skin" on connecting and on a
/// skin change: the 24 visualizer colors and the playlist's text and its
/// background.
@MainActor
@Observable
final class PanelFeed {
    static let enabledKey = "panelFeed.enabled"
    static let portKey = "panelFeed.port"
    static let defaultPort: UInt16 = 24248

    var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            Storage.defaults.set(isEnabled, forKey: Self.enabledKey)
            isEnabled ? start() : stop()
        }
    }

    var port: UInt16 {
        let saved = Storage.defaults.integer(forKey: Self.portKey)
        return (1...65535).contains(saved) ? UInt16(saved) : Self.defaultPort
    }

    /// For Preferences: where it listens and who's connected, or why it doesn't.
    private(set) var state = ""

    @ObservationIgnored private let model: PlayerModel
    @ObservationIgnored private weak var windows: WindowManager?
    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var clients: [Client] = []
    @ObservationIgnored private let visualizer = Visualizer()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var sequence: UInt32 = 0
    /// The visualizer as the main window would show it (nil: the skin's background).
    @ObservationIgnored private var visualizerFrame: Bitmap?
    /// What was last sent, by frame type.
    @ObservationIgnored private var sent: [UInt8: Bitmap] = [:]
    @ObservationIgnored private var published: (key: StatusKey, position: Double, at: Date)?

    @MainActor private final class Client {
        let connection: NWConnection
        var isReady = false
        /// Sends not yet taken by the network: a slow client skips frames.
        var pending = 0

        init(_ connection: NWConnection) {
            self.connection = connection
        }
    }

    private struct StatusKey: Equatable {
        var state: PlaybackStatus
        var visualizer: VisualizerSettings
        var url: URL?
        var display: String?
        var title: String?
        var artist: String?
        var album: String?
        var duration: Double?
    }

    init(model: PlayerModel, windows: WindowManager) {
        self.model = model
        self.windows = windows
        isEnabled = Storage.defaults.bool(forKey: Self.enabledKey)
        if isEnabled { start() }
    }

    // MARK: - Listening

    private func start() {
        guard listener == nil, let port = NWEndpoint.Port(rawValue: port) else { return }
        let parameters = NWParameters.tcp
        let websocket = NWProtocolWebSocket.Options()
        websocket.autoReplyPing = true
        parameters.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)
        // Loopback only: nothing off this Mac can connect.
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: port)
        parameters.acceptLocalOnly = true
        parameters.allowLocalEndpointReuse = true
        guard let listener = try? NWListener(using: parameters) else {
            state = "Can't listen on port \(port)."
            return
        }
        listener.stateUpdateHandler = { [weak self] newState in
            MainActor.assumeIsolated { self?.listenerChanged(newState) }
        }
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated { self?.accept(connection) }
        }
        self.listener = listener
        listener.start(queue: .main)
    }

    private func stop() {
        listener?.cancel()
        listener = nil
        for client in clients { client.connection.cancel() }
        clients = []
        clientsChanged()
        state = ""
    }

    private func listenerChanged(_ newState: NWListener.State) {
        switch newState {
        case .ready:
            updateState()
        case .failed(let error):
            listener?.cancel()
            listener = nil
            if case .posix(let code) = error, code == .EADDRINUSE {
                state = "Port \(port) is in use by another app."
            } else {
                state = "Stopped: \(error.localizedDescription)"
            }
        default:
            break
        }
    }

    private func updateState() {
        guard listener != nil else { return }
        let connected = clients.filter(\.isReady).count
        state = "On ws://127.0.0.1:\(port)" + (connected == 0 ? "." : connected == 1 ? ", 1 app connected." : ", \(connected) apps connected.")
    }

    // MARK: - Clients

    private func accept(_ connection: NWConnection) {
        let client = Client(connection)
        clients.append(client)
        connection.stateUpdateHandler = { [weak self, weak client] newState in
            MainActor.assumeIsolated {
                guard let self, let client else { return }
                switch newState {
                case .ready:
                    client.isReady = true
                    self.receive(client)
                    self.clientsChanged()
                    self.greet(client)
                case .failed, .cancelled, .waiting:
                    self.drop(client)
                default:
                    break
                }
            }
        }
        connection.start(queue: .main)
    }

    private func drop(_ client: Client?) {
        guard let client, let index = clients.firstIndex(where: { $0 === client }) else { return }
        clients.remove(at: index)
        client.connection.cancel()
        clientsChanged()
    }

    /// Clients send nothing that matters, but reading notices them leave.
    private func receive(_ client: Client) {
        client.connection.receiveMessage { [weak self, weak client] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self, let client else { return }
                if error != nil || (data == nil && isComplete) {
                    self.drop(client)
                } else {
                    self.receive(client)
                }
            }
        }
    }

    private func clientsChanged() {
        let ready = clients.contains(where: \.isReady)
        if ready, timer == nil {
            let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else if !ready {
            timer?.invalidate()
            timer = nil
            published = nil
            sent = [:]
        }
        updateState()
    }

    /// A new client gets the colors, the state and the frames as they are now.
    private func greet(_ client: Client) {
        send(skinMessage(), to: [client])
        publishStatus(force: true, to: [client])
        for (type, bitmap) in frames() { sendFrame(bitmap, type: type, to: [client]) }
    }

    // MARK: - Frames

    private func tick() {
        guard let windows else { return }
        // The visualizer runs as in the main window: still when paused, gone when stopped or off.
        if windows.visualizerSettings.mode == .off || model.status == .stopped {
            visualizerFrame = nil
        } else if model.status == .playing {
            visualizerFrame = visualizer.render(
                samples: model.engine.samples.latest(1024), colors: windows.skin.visColors, settings: windows.visualizerSettings, small: false)
        }
        for (type, bitmap) in frames() where sent[type] != bitmap {
            sent[type] = bitmap
            sendFrame(bitmap, type: type)
        }
    }

    /// The display and the title, cut from the main window drawn now.
    private func frames() -> [(UInt8, Bitmap)] {
        guard let windows else { return [] }
        let window = MainWindowRenderer.render(windows.skin, windows.main.panelState(visualizer: visualizerFrame))
        return [
            (PanelFeedFormat.display, window.cropped(to: PanelFeedFormat.displayRect)),
            (PanelFeedFormat.marquee, window.cropped(to: PanelFeedFormat.marqueeRect)),
        ]
    }

    private func sendFrame(_ bitmap: Bitmap, type: UInt8, to targets: [Client]? = nil) {
        sequence &+= 1
        send(PanelFeedFormat.frame(bitmap, type: type, sequence: sequence), binary: true, to: targets)
    }

    private func send(_ data: Data, binary: Bool = false, to targets: [Client]? = nil) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: binary ? .binary : .text)
        let context = NWConnection.ContentContext(identifier: binary ? "frame" : "message", metadata: [metadata])
        for client in targets ?? clients where client.isReady {
            if binary, client.pending > 4 { continue }
            client.pending += 1
            client.connection.send(
                content: data, contentContext: context, isComplete: true,
                completion: .contentProcessed { [weak self, weak client] error in
                    MainActor.assumeIsolated {
                        client?.pending -= 1
                        if error != nil { self?.drop(client) }
                    }
                })
        }
    }

    // MARK: - Status and skin

    /// The player changed (state, track, a seek...).
    func playerChanged() { publishStatus(force: false) }

    /// The visualizer's mode or options changed.
    func visualizerChanged() { publishStatus(force: false) }

    func skinChanged() {
        guard clients.contains(where: \.isReady) else { return }
        send(skinMessage())
    }

    /// Sends the status if something in it changed, or the position jumped
    /// away from where counting on would have it.
    private func publishStatus(force: Bool, to targets: [Client]? = nil) {
        guard let windows, clients.contains(where: \.isReady) else { return }
        let track = model.displayedTrack
        let status = model.status
        let elapsed = model.elapsed
        let display = track.map { (model.currentIndex.map { "\($0 + 1). " } ?? "") + $0.displayName }
        let key = StatusKey(
            state: status, visualizer: windows.visualizerSettings, url: track?.url, display: display, title: track?.title, artist: track?.artist,
            album: track?.album, duration: model.duration)
        let now = Date()
        if !force, let published {
            let expected = published.position + (published.key.state == .playing ? now.timeIntervalSince(published.at) : 0)
            if published.key == key, abs(expected - elapsed) <= 1.5 { return }
        }
        published = (key, elapsed, now)
        var trackObject: Any = NSNull()
        if let track {
            trackObject = [
                "title": track.title as Any? ?? NSNull(), "artist": track.artist as Any? ?? NSNull(), "album": track.album as Any? ?? NSNull(),
                "display": display ?? track.displayName, "duration": model.duration as Any? ?? NSNull(),
            ] as [String: Any]
        }
        let message: [String: Any] = [
            "type": "status", "state": Self.name(status), "visMode": key.visualizer.mode.rawValue,
            "visualizer": Self.options(key.visualizer), "track": trackObject, "position": elapsed,
            "sentAt": now.timeIntervalSince1970,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes]) else { return }
        send(data, to: targets)
    }

    private func skinMessage() -> Data {
        guard let skin = windows?.skin else { return Data() }
        let message: [String: Any] = [
            "type": "skin", "visColors": skin.visColors.map(PanelFeedFormat.hex),
            "text": PanelFeedFormat.hex(skin.playlistStyle.normal),
            "textBackground": PanelFeedFormat.hex(skin.playlistStyle.normalBackground),
        ]
        return (try? JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes])) ?? Data()
    }

    /// The visualizer's options, as its menu has them.
    private static func options(_ settings: VisualizerSettings) -> [String: Any] {
        [
            "mode": settings.mode.rawValue, "analyzerStyle": settings.analyzerStyle.rawValue, "bandWidth": settings.bandWidth.rawValue,
            "peaks": settings.peaks, "barFalloff": settings.barFalloff.rawValue, "peakFalloff": settings.peakFalloff.rawValue,
            "oscilloscopeStyle": settings.oscilloscopeStyle.rawValue,
        ]
    }

    private static func name(_ status: PlaybackStatus) -> String {
        switch status {
        case .playing: "playing"
        case .paused: "paused"
        case .stopped: "stopped"
        }
    }
}
