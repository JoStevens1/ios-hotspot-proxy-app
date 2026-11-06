import Foundation
import Combine
import AVFAudio
import MediaPlayer
import UIKit
import Darwin

/// Drives the SwiftUI shell from the relay's one-second snapshots.
///
/// Totals are process-lifetime cumulative and come straight from `TrafficCounters`.
/// Speed is derived here by differencing consecutive snapshots, so it is a
/// measured rate rather than a second counter that could drift from the totals.
@MainActor
final class RelayViewModel: ObservableObject {
    enum Status: Equatable {
        case starting
        case listening(port: UInt16)
        case failed(String)
    }

    /// One address a client could point at, kept with the interface it came from.
    /// Picking a single "the" address was wrong: the hotspot gateway and the
    /// Wi-Fi address live on different interfaces and only the user knows which
    /// way their client is arriving.
    struct Endpoint: Identifiable, Equatable {
        let interface: String
        let address: String
        let role: String

        var id: String { "\(interface)|\(address)" }
    }

    @Published private(set) var status: Status = .starting
    @Published private(set) var endpoints: [Endpoint] = []
    @Published private(set) var backgroundActive = false
    @Published private(set) var uploadBytes: UInt64 = 0
    @Published private(set) var downloadBytes: UInt64 = 0
    @Published private(set) var uploadBytesPerSecond: UInt64 = 0
    @Published private(set) var downloadBytesPerSecond: UInt64 = 0
    @Published private(set) var activeTCP = 0
    @Published private(set) var activeUDP = 0
    @Published private(set) var log: [LogEntry] = []

    struct LogEntry: Identifiable, Equatable {
        let id = UUID()
        let at: Date
        let text: String
    }

    var activeTotal: Int { activeTCP + activeUDP }

    private let relay = NetworkTCPRelay(countingEnabled: true)
    private let keepAlive = BackgroundKeepAlive()
    private var timer: Timer?
    private var lastSample: (upload: UInt64, download: UInt64, at: Date)?

    func start() {
        guard timer == nil else { return }
        relay.eventHandler = { [weak self] event in
            Task { @MainActor in
                guard let self else { return }
                // A listener that dies after startup never reaches the one-shot
                // start callback, so without this the screen keeps advertising an
                // endpoint that stopped answering.
                if event == .listenerFailed {
                    self.status = .failed("listener failed")
                    self.endpoints = []
                    // Nothing left to keep alive for. Holding the audio session
                    // would drain the battery indefinitely while serving nobody.
                    self.keepAlive.stop()
                    self.backgroundActive = false
                }
                self.append(Self.describe(event))
            }
        }
        relay.start { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success(let port):
                    self.status = .listening(port: port)
                    self.endpoints = Self.localEndpoints()
                    self.append("listening on \(port)")
                    self.keepAlive.start()
                    self.append(self.keepAlive.isActive
                                ? "background audio holding the app awake"
                                : "background audio unavailable")
                case .failure(let error):
                    let reason = Self.describe(error)
                    self.status = .failed(reason)
                    self.append(reason)
                }
            }
        }

        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Bounded ring: the shell keeps the most recent entries and nothing else, so
    /// a long-running proxy cannot grow this without limit.
    private static let logLimit = 50

    private func append(_ text: String) {
        log.append(LogEntry(at: Date(), text: text))
        if log.count > Self.logLimit {
            log.removeFirst(log.count - Self.logLimit)
        }
    }

    private static func errnoText(_ code: Int32) -> String {
        "errno \(code) \(String(cString: strerror(code)))"
    }

    private static func describe(_ event: NetworkTCPRelay.Event) -> String {
        switch event {
        case .sessionOpened: return "session opened"
        case .sessionClosed: return "session closed"
        case .connectEstablished: return "CONNECT established"
        case .connectRejected(let reply): return String(format: "CONNECT rejected 0x%02x", reply)
        case .udpAssociated: return "UDP ASSOCIATE established"
        case .udpAssociateFailed: return "UDP ASSOCIATE failed"
        case .udpSendFailed(let code):
            return "UDP send failed: \(errnoText(code))"
        case let .udpClosed(sent, sendFailures, lastErrno, received, firstReply):
            var text = "UDP closed: sent \(sent)"
            if sendFailures > 0 {
                text += ", \(sendFailures) failed (\(errnoText(lastErrno)))"
            }
            text += ", got \(received)"
            text += firstReply >= 0 ? ", first reply \(firstReply) ms" : ", no reply"
            return text
        case .listenerFailed: return "listener failed — no longer accepting connections"
        }
    }

    private func sample() {
        // Addresses are re-read every tick rather than once at startup. Toggling
        // Wi-Fi or turning on the hotspot changes them, and the old code showed
        // whatever happened to be there the moment the listener came up.
        let current = Self.localEndpoints()
        if current != endpoints { endpoints = current }

        // Cheap self-heal: an interruption (a call, a route change) stops the
        // audio session, and without it the app is suspended the next time it
        // leaves the screen. This is the foreground backstop only; the keepalive's
        // own off-main watchdog is what covers the backgrounded case.
        keepAlive.resumeIfNeeded()
        if backgroundActive != keepAlive.isActive { backgroundActive = keepAlive.isActive }

        relay.snapshot { [weak self] snapshot in
            Task { @MainActor in
                guard let self else { return }
                let now = Date()
                if let previous = self.lastSample {
                    let elapsed = now.timeIntervalSince(previous.at)
                    if elapsed >= 0.2 {
                        self.uploadBytesPerSecond =
                            Self.rate(from: previous.upload, to: snapshot.uploadBytes, seconds: elapsed)
                        self.downloadBytesPerSecond =
                            Self.rate(from: previous.download, to: snapshot.downloadBytes, seconds: elapsed)
                    }
                }
                self.lastSample = (snapshot.uploadBytes, snapshot.downloadBytes, now)
                self.uploadBytes = snapshot.uploadBytes
                self.downloadBytes = snapshot.downloadBytes
                self.activeTCP = snapshot.activeTCP
                self.activeUDP = snapshot.activeUDP
            }
        }
    }

    private static func rate(from previous: UInt64, to current: UInt64, seconds: TimeInterval) -> UInt64 {
        guard current >= previous else { return 0 }
        return UInt64(Double(current - previous) / seconds)
    }

    private static func describe(_ error: NetworkTCPRelay.RelayError) -> String {
        switch error {
        case .alreadyRunning: return "relay already running"
        case .listenerSetup: return "listener setup failed"
        case .listenerFailed: return "listener failed"
        case .cancelled: return "listener cancelled"
        }
    }

    /// Every IPv4 address a LAN or hotspot client could actually reach, newest
    /// state each call. Cellular is left out on purpose: carrier NAT makes it
    /// unreachable from outside, and offering it as the address to type in is
    /// worse than offering nothing.
    static func localEndpoints() -> [Endpoint] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(first) }

        var found: [Endpoint] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee
            guard let addr = interface.ifa_addr,
                  addr.pointee.sa_family == sa_family_t(AF_INET),
                  interface.ifa_flags & UInt32(IFF_UP) != 0 else {
                continue
            }
            let name = String(cString: interface.ifa_name)
            guard let role = Self.role(for: name) else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host,
                              socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else {
                continue
            }
            found.append(Endpoint(interface: name, address: String(cString: host), role: role))
        }
        // Hotspot first: it is the address a tethered client needs and the one
        // the previous single-address picker could never return.
        return found.sorted { Self.rank($0.role) < Self.rank($1.role) }
    }

    /// `nil` means "never worth showing". Anything not recognised is still shown
    /// under its own interface name rather than guessed at or dropped.
    private static func role(for interface: String) -> String? {
        switch true {
        case interface.hasPrefix("lo"),
             interface.hasPrefix("utun"),
             interface.hasPrefix("ipsec"),
             interface.hasPrefix("awdl"),
             interface.hasPrefix("llw"),
             interface.hasPrefix("pdp_ip"):
            return nil
        case interface.hasPrefix("bridge"), interface.hasPrefix("ap"):
            return "HOTSPOT"
        case interface == "en0":
            return "WI-FI"
        default:
            return interface.uppercased()
        }
    }

    private static func rank(_ role: String) -> Int {
        switch role {
        case "HOTSPOT": return 0
        case "WI-FI": return 1
        default: return 2
        }
    }
}

/// iOS suspends an ordinary app seconds after it leaves the screen, taking the
/// listener and every live connection with it. An active audio session is what
/// keeps a plain app scheduled, so the relay plays a tone for as long as it is
/// serving. `.mixWithOthers` leaves whatever the user is actually listening to
/// alone.
///
/// The tone has to be genuinely present, not merely declared. The audio server
/// holds an output activity assertion while output is flowing, and an app whose
/// output goes silent for "too long" loses it — the failure being "declares
/// `audio` but produces nothing", which suspends the app about 30 s after
/// backgrounding and takes the relay with it. Digital zeroes and a muted player
/// node are the two states with the least evidence behind them; see
/// docs/KEEPALIVE-TODO.md. Generating the tone also removes the blank-WAV asset
/// the pre-Swift app carried.
@MainActor
final class BackgroundKeepAlive {
    /// ~-40 dBFS peak. Unambiguously present at the mixer, quiet enough not to be a
    /// nuisance across a room.
    private static let tonePeak: Float = 0.01
    /// One second, so the loop seam is the only discontinuity and a re-arm
    /// reschedules cheaply.
    private static let toneFrames: AVAudioFrameCount = 44_100
    /// Three cascaded one-pole stages at 0.95, i.e. −120 dB/decade and a ~350 Hz
    /// corner. Measured across a dozen buffers this leaves under 0.002 % of the
    /// power above 8 kHz, against ~0.5 % for a single stage at 0.99. Three stages
    /// costs three milliseconds at launch and makes the band-limiting
    /// unambiguous, which is worth having given the whole design rests on what
    /// this signal looks like.
    private static let toneStages = 3
    private static let tonePole: Float = 0.95

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let tone: AVAudioPCMBuffer?
    private var wanted = false
    private var observers: [NSObjectProtocol] = []
    private var watchdog: DispatchSourceTimer?

    /// Off the main thread on purpose: iOS kills a process that exceeds 80% average
    /// CPU over a 60 s window (`cpu_resource_fatal`), and looping audio is free
    /// while main-thread polling is not.
    private let watchdogQueue = DispatchQueue(
        label: "com.nanako.socksbypass.keepalive", qos: .utility
    )

    var isActive: Bool { engine.isRunning && player.isPlaying }

    init() {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1),
              let buffer = Self.makeTone(format: format) else {
            tone = nil
            return
        }
        tone = buffer
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    /// Band-limited noise, normalised to `tonePeak`, crossfaded at the seam so the
    /// loop point is not a click. Noise rather than a tone, because broadband hiss
    /// at this level is masked by room noise; deliberately not near-ultrasonic,
    /// because there is no evidence that helps and it risks an audible whine.
    private static func makeTone(format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: toneFrames),
              let samples = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = toneFrames
        let count = Int(toneFrames)

        // Band-limit before scaling, or the noise sits up in the part of the band
        // the phone cannot reproduce. In place, one pass per stage: `previous`
        // carries the filter state and each sample is read before it is written.
        for i in 0 ..< count { samples[i] = Float.random(in: -1 ... 1) }
        for _ in 0 ..< toneStages {
            var previous: Float = 0
            for i in 0 ..< count {
                previous = tonePole * previous + (1 - tonePole) * samples[i]
                samples[i] = previous
            }
        }

        // Wrap-around crossfade, so the one-second splice is not a discontinuity.
        // Every splice would otherwise be a click — audible, and an amplitude
        // transient the audio server can see.
        let fade = 1_024
        for i in 0 ..< fade {
            let t = Float(i) / Float(fade)
            samples[count - fade + i] = samples[count - fade + i] * (1 - t) + samples[i] * t
        }

        // Normalise by the measured peak so `tonePeak` means what it says.
        var peak: Float = 0
        for i in 0 ..< count { peak = max(peak, abs(samples[i])) }
        guard peak > 0 else { return buffer }
        let scale = tonePeak / peak
        for i in 0 ..< count { samples[i] *= scale }
        return buffer
    }

    func start() {
        guard !wanted else { return }
        wanted = true
        observeSession()
        startWatchdog()
        // A mode, not a permanent setting: true only while the relay is serving.
        // Free when the app is already backgrounded, and it gives the foreground
        // case a path that no OS heuristic can take away.
        UIApplication.shared.isIdleTimerDisabled = true
        publishNowPlaying()
        resumeIfNeeded()
    }

    /// Interruption is the documented reason an audio session goes away, but a
    /// route change (headphones, AirPods, the hotspot rearranging interfaces) and a
    /// media-services reset tear down the output just as hard and just as silently.
    /// Re-arming on all three is the difference between surviving minutes and
    /// surviving hours.
    private func observeSession() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()

        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: session, queue: .main
        ) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
            Task { @MainActor in self?.resumeIfNeeded() }
        })
        observers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: session, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.resumeIfNeeded() }
        })
        observers.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.resumeIfNeeded() }
        })
    }

    /// Apple DTS: an app registered as the Now Playing app is "generally safe from
    /// memory termination" while background memory stays under ~100 MB, and it is
    /// the recommended shape over a purely mixable session. What this relay holds
    /// in the background is the connection table and a 50-entry log, so that is
    /// nowhere near the ceiling.
    private func publishNowPlaying() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: "SOCKS proxy",
            MPMediaItemPropertyArtist: "serving",
            MPNowPlayingInfoPropertyIsLiveStream: true,
        ]
    }

    /// The foreground `Timer` cannot recover an interruption on its own. Losing the
    /// audio session is precisely what lets iOS suspend the app, and a suspended
    /// app's run-loop timer stops firing, so polling is dead exactly when it would
    /// be needed. This runs off the main thread so it does not share fate with the
    /// main run loop; it still only works while the session itself is holding the
    /// process awake, so it is a net rather than a replacement.
    private func startWatchdog() {
        guard watchdog == nil else { return }
        let watchdog = DispatchSource.makeTimerSource(queue: watchdogQueue)
        watchdog.schedule(deadline: .now() + 1, repeating: 1)
        watchdog.setEventHandler { [weak self] in
            Task { @MainActor in self?.resumeIfNeeded() }
        }
        self.watchdog = watchdog
        watchdog.resume()
    }

    /// Releases the session for good. `wanted` is cleared first so the watchdog does
    /// not immediately restart what this just stopped.
    func stop() {
        wanted = false
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers = []
        watchdog?.cancel()
        watchdog = nil
        player.stop()
        engine.stop()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        try? AVAudioSession.sharedInstance().setActive(false)
        UIApplication.shared.isIdleTimerDisabled = false
    }

    func resumeIfNeeded() {
        guard wanted, !isActive, let tone else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            player.stop()                              // clears any stale schedule
            if !engine.isRunning { try engine.start() }
            player.scheduleBuffer(tone, at: nil, options: .loops)
            player.play()
        } catch {
            // Left inactive on purpose. The next tick tries again, and the shell
            // shows the state rather than pretending the app will survive
            // backgrounding.
        }
    }
}
