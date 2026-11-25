import AppKit
import Foundation

@MainActor
protocol PlayerSource: AnyObject {
    func start()
    func stop()
    /// true quand un widget est à l'écran (écran verrouillé, aperçu…) : travail de précision actif.
    func setForeground(_ foreground: Bool)
    func togglePlayPause()
    func next()
    func previous()
    func seek(to seconds: Double)
}

// MARK: - MediaRemote (via mediaremote-adapter)

/// Chemins du mediaremote-adapter embarqué dans l'app (Resources/MediaRemoteAdapter).
struct AdapterPaths {
    let script: String
    let framework: String
    let testClient: String

    static func bundled() -> AdapterPaths? {
        guard let dir = Bundle.main.resourceURL?.appendingPathComponent("MediaRemoteAdapter") else { return nil }
        let paths = AdapterPaths(
            script: dir.appendingPathComponent("mediaremote-adapter.pl").path,
            framework: dir.appendingPathComponent("MediaRemoteAdapter.framework").path,
            testClient: dir.appendingPathComponent("MediaRemoteAdapterTestClient").path
        )
        let fm = FileManager.default
        guard fm.fileExists(atPath: paths.script), fm.fileExists(atPath: paths.framework) else { return nil }
        return paths
    }

    func arguments(_ command: [String]) -> [String] {
        [script, framework, testClient] + command
    }

    func makeProcess(_ command: [String]) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = arguments(command)
        process.standardError = FileHandle.nullDevice
        return process
    }

    /// `test` renvoie 0 quand l'adapter fonctionne sur ce macOS.
    func isWorking() async -> Bool {
        let process = makeProcess(["test"])
        process.standardOutput = FileHandle.nullDevice
        return await withCheckedContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus == 0) }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(returning: false)
            }
        }
    }
}

@MainActor
final class MediaRemoteSource: PlayerSource {
    private let paths: AdapterPaths
    private unowned let model: NowPlaying
    private var process: Process?
    private var buffer = Data()
    private var state: [String: Any] = [:]
    private var artworkSignature: String?
    private var stopped = true

    /// MediaRemote est ~1 s en retard sur Spotify : on mesure l'écart avec la position
    /// exacte donnée par Spotify (AppleScript) et on le corrige.
    private var spotifyOffset: Double = 0
    private var syncTimer: Timer?

    init(paths: AdapterPaths, model: NowPlaying) {
        self.paths = paths
        self.model = model
    }

    func start() {
        stopped = false
        launch()
    }

    /// Le recalage sur Spotify (AppleScript toutes les 3 s) ne sert qu'aux widgets affichés.
    func setForeground(_ foreground: Bool) {
        syncTimer?.invalidate()
        syncTimer = nil
        guard foreground, !stopped else { return }
        syncWithSpotify()
        syncTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncWithSpotify() }
        }
        syncTimer?.tolerance = 0.5
    }

    func stop() {
        stopped = true
        syncTimer?.invalidate()
        syncTimer = nil
        process?.terminate()
        process = nil
    }

    private var isSpotify: Bool {
        (state["bundleIdentifier"] as? String)?.hasPrefix("com.spotify.client") == true
    }

    /// Position brute selon MediaRemote, à l'instant `date`.
    private func mediaRemoteElapsed(at date: Date) -> Double {
        var value = number("elapsedTimeMicros") / 1_000_000
        if state["playing"] as? Bool == true, let ts = state["timestampEpochMicros"] as? Double {
            value += date.timeIntervalSince1970 - ts / 1_000_000
        }
        return value
    }

    private func syncWithSpotify() {
        guard isSpotify, model.isPlaying else { return }
        let source = "if application \"Spotify\" is running then tell application \"Spotify\" to return player position"
        var error: NSDictionary?
        guard let result = NSAppleScript(source: source)?.executeAndReturnError(&error), error == nil else { return }
        let now = Date()
        let position = result.doubleValue
        guard position > 0 else { return }
        let measured = position - mediaRemoteElapsed(at: now)
        // Ignore les valeurs absurdes (changement de morceau en cours, seek…).
        guard abs(measured) < 5 else { return }
        spotifyOffset = measured
        model.elapsedAtTimestamp = position
        model.timestamp = now
    }

    private func launch() {
        let process = paths.makeProcess(["stream", "--micros", "--debounce=50"])
        let pipe = Pipe()
        process.standardOutput = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.consume(data) }
            }
        }
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.processDidExit() }
            }
        }
        buffer.removeAll()
        do {
            try process.run()
            self.process = process
        } catch {
            NSLog("LockPlayer: impossible de lancer mediaremote-adapter: \(error)")
            processDidExit()
        }
    }

    private func processDidExit() {
        process = nil
        guard !stopped else { return }
        // Relance automatique si le flux s'arrête.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.stopped, self.process == nil else { return }
                self.launch()
            }
        }
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<newline)
            buffer = buffer.subdata(in: buffer.index(after: newline)..<buffer.endIndex)
            handle(line)
        }
    }

    private func handle(_ line: Data) {
        guard !line.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let payload = object["payload"] as? [String: Any] else { return }

        if object["diff"] as? Bool == true {
            for (key, value) in payload {
                if value is NSNull { state.removeValue(forKey: key) } else { state[key] = value }
            }
        } else {
            state = payload
        }
        publish()
    }

    private func publish() {
        guard let title = state["title"] as? String, !title.isEmpty else {
            model.clear()
            artworkSignature = nil
            return
        }
        let artist = state["artist"] as? String ?? ""
        let album = state["album"] as? String ?? ""
        if model.title != title { model.title = title }
        if model.artist != artist { model.artist = artist }
        if model.album != album { model.album = album }

        model.duration = number("durationMicros") / 1_000_000
        model.elapsedAtTimestamp = number("elapsedTimeMicros") / 1_000_000 + (isSpotify ? spotifyOffset : 0)
        if let ts = state["timestampEpochMicros"] as? Double {
            model.timestamp = Date(timeIntervalSince1970: ts / 1_000_000)
        } else {
            model.timestamp = Date()
        }
        model.isPlaying = state["playing"] as? Bool ?? false

        let base64 = state["artworkData"] as? String
        let signature = base64.map { "\($0.count)|\($0.prefix(48))|\($0.suffix(48))" }
        if signature != artworkSignature {
            artworkSignature = signature
            let image = base64
                .flatMap { Data(base64Encoded: $0, options: .ignoreUnknownCharacters) }
                .flatMap(NSImage.init(data:))
            // Garder l'ancienne pochette tant que la nouvelle n'est pas arrivée sur le même morceau.
            if image != nil || base64 == nil { model.setArtwork(image) }
        }
    }

    private func number(_ key: String) -> Double {
        (state[key] as? NSNumber)?.doubleValue ?? 0
    }

    private func run(_ command: [String]) {
        let process = paths.makeProcess(command)
        process.standardOutput = FileHandle.nullDevice
        try? process.run()
    }

    func togglePlayPause() {
        model.setPlaying(!model.isPlaying)
        run(["send", "2"])
    }

    func next() { run(["send", "4"]) }
    func previous() { run(["send", "5"]) }

    func seek(to seconds: Double) {
        model.setPosition(seconds)
        run(["seek", String(Int(max(0, seconds) * 1_000_000))])
    }
}

// MARK: - Secours : AppleScript Spotify

@MainActor
final class SpotifyScriptSource: PlayerSource {
    private unowned let model: NowPlaying
    private var timer: Timer?
    private var artworkURL: String?

    private static let separator = "‖"
    private static let pollScript = """
    if application "Spotify" is running then
        tell application "Spotify"
            if player state is stopped then return "STOPPED"
            set t to current track
            set s to "\(separator)"
            return (name of t) & s & (artist of t) & s & (album of t) & s & (duration of t) & s & (player position as string) & s & (player state as string) & s & (artwork url of t)
        end tell
    end if
    return "NONE"
    """

    init(model: NowPlaying) {
        self.model = model
    }

    func start() {
        setForeground(false)
    }

    /// Une interrogation par seconde quand c'est affiché, toutes les 10 s sinon.
    func setForeground(_ foreground: Bool) {
        timer?.invalidate()
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: foreground ? 1 : 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        timer?.tolerance = foreground ? 0.2 : 2
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        var error: NSDictionary?
        guard let output = NSAppleScript(source: Self.pollScript)?.executeAndReturnError(&error).stringValue else {
            return
        }
        let parts = output.components(separatedBy: Self.separator)
        guard parts.count >= 7 else {
            model.clear()
            artworkURL = nil
            return
        }
        if model.title != parts[0] { model.title = parts[0] }
        if model.artist != parts[1] { model.artist = parts[1] }
        if model.album != parts[2] { model.album = parts[2] }
        model.duration = (Double(parts[3]) ?? 0) / 1000
        // AppleScript utilise la virgule décimale en français.
        model.elapsedAtTimestamp = Double(parts[4].replacingOccurrences(of: ",", with: ".")) ?? 0
        model.timestamp = Date()
        model.isPlaying = parts[5] == "playing"

        let url = parts[6]
        if url != artworkURL {
            artworkURL = url
            loadArtwork(url)
        }
    }

    private func loadArtwork(_ string: String) {
        guard let url = URL(string: string) else {
            model.setArtwork(nil)
            return
        }
        Task { [weak self] in
            let image = try? await URLSession.shared.data(from: url).0
            guard let self, self.artworkURL == string else { return }
            self.model.setArtwork(image.flatMap(NSImage.init(data:)))
        }
    }

    private func tell(_ command: String) {
        let source = "if application \"Spotify\" is running then tell application \"Spotify\" to \(command)"
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
    }

    func togglePlayPause() {
        model.setPlaying(!model.isPlaying)
        tell("playpause")
    }

    func next() { tell("next track"); poll() }
    func previous() { tell("previous track"); poll() }

    func seek(to seconds: Double) {
        model.setPosition(seconds)
        tell("set player position to \(String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), seconds))")
    }
}
