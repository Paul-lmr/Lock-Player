import CryptoKit
import Foundation
import Observation

struct LyricLine: Identifiable, Equatable {
    let id: Int
    let time: Double
    let text: String
}

enum LyricsState: Equatable {
    case idle
    case loading
    case synced([LyricLine])
    case plain([String])
    case instrumental
    case notFound
    case failed
}

/// Ce qu'on garde en cache pour un morceau (réponse LRCLIB utile).
struct CachedLyrics: Codable {
    var synced: String?
    var plain: String?
    var instrumental: Bool

    var state: LyricsState {
        if instrumental { return .instrumental }
        if let synced, !synced.isEmpty {
            let lines = LRCParser.parse(synced)
            if !lines.isEmpty { return .synced(lines) }
        }
        if let plain, !plain.isEmpty {
            return .plain(plain.components(separatedBy: .newlines))
        }
        return .notFound
    }
}

@MainActor
@Observable
final class LyricsStore {
    private(set) var state: LyricsState = .idle

    @ObservationIgnored private var key: String?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var memory: [String: CachedLyrics] = [:]

    func update(title: String, artist: String, album: String, duration: Double) {
        let newKey = "\(artist.lowercased())\u{1F}\(title.lowercased())"
        guard newKey != key else { return }
        key = newKey
        task?.cancel()

        guard !title.isEmpty else {
            state = .idle
            return
        }
        if let cached = memory[newKey] ?? DiskCache.load(newKey) {
            memory[newKey] = cached
            state = cached.state
            return
        }

        state = .loading
        task = Task { [weak self] in
            // Laisse le temps à la durée d'arriver et évite de spammer LRCLIB en zappant.
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            let result = await LRCLib.fetch(title: title, artist: artist, album: album, duration: duration)
            guard let self, !Task.isCancelled, self.key == newKey else { return }
            switch result {
            case let .success(cached):
                let value = cached ?? CachedLyrics(synced: nil, plain: nil, instrumental: false)
                self.memory[newKey] = value
                DiskCache.save(value, for: newKey)
                self.state = value.state
            case .failure:
                self.state = .failed
                self.key = nil // on réessaiera au prochain update
            }
        }
    }

    func retry(title: String, artist: String, album: String, duration: Double) {
        key = nil
        update(title: title, artist: artist, album: album, duration: duration)
    }

    static func currentIndex(in lines: [LyricLine], at time: Double) -> Int? {
        // Petite avance pour que la ligne s'allume pile au chant.
        let t = time + 0.25
        var low = 0, high = lines.count - 1, found: Int?
        while low <= high {
            let mid = (low + high) / 2
            if lines[mid].time <= t {
                found = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return found
    }
}

// MARK: - LRCLIB

enum LRCLib {
    private struct Record: Decodable {
        let duration: Double?
        let instrumental: Bool?
        let plainLyrics: String?
        let syncedLyrics: String?
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.httpAdditionalHeaders = ["User-Agent": "LockPlayer/1.0 (macOS lock screen player)"]
        return URLSession(configuration: config)
    }()

    static func fetch(title: String, artist: String, album: String, duration: Double) async -> Result<CachedLyrics?, Error> {
        do {
            // 1. Correspondance exacte (titre + artiste + album + durée).
            if duration > 0 {
                var components = URLComponents(string: "https://lrclib.net/api/get")!
                components.queryItems = [
                    .init(name: "track_name", value: title),
                    .init(name: "artist_name", value: artist),
                    .init(name: "album_name", value: album),
                    .init(name: "duration", value: String(Int(duration.rounded()))),
                ]
                let (data, response) = try await session.data(from: components.url!)
                if (response as? HTTPURLResponse)?.statusCode == 200,
                   let record = try? JSONDecoder().decode(Record.self, from: data) {
                    return .success(cached(record))
                }
            }

            // 2. Recherche plus souple (titre nettoyé : "- Remastered", "(feat. …)").
            for candidate in Array(Set([title, cleaned(title)])) {
                var components = URLComponents(string: "https://lrclib.net/api/search")!
                components.queryItems = [
                    .init(name: "track_name", value: candidate),
                    .init(name: "artist_name", value: artist),
                ]
                let (data, response) = try await session.data(from: components.url!)
                guard (response as? HTTPURLResponse)?.statusCode == 200,
                      let records = try? JSONDecoder().decode([Record].self, from: data),
                      let best = best(records, duration: duration) else { continue }
                return .success(cached(best))
            }
            return .success(nil)
        } catch {
            return .failure(error)
        }
    }

    private static func cached(_ record: Record) -> CachedLyrics {
        CachedLyrics(synced: record.syncedLyrics, plain: record.plainLyrics, instrumental: record.instrumental ?? false)
    }

    private static func best(_ records: [Record], duration: Double) -> Record? {
        let usable = records.filter { duration <= 0 || abs(($0.duration ?? duration) - duration) <= 4 }
        return usable.first { !($0.syncedLyrics ?? "").isEmpty }
            ?? usable.first { !($0.plainLyrics ?? "").isEmpty }
    }

    static func cleaned(_ title: String) -> String {
        var result = title
        if let range = result.range(of: " - ") { result = String(result[..<range.lowerBound]) }
        if let regex = try? NSRegularExpression(pattern: #"\s*[\(\[](feat\.?|with|ft\.?)[^\)\]]*[\)\]]"#, options: .caseInsensitive) {
            result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "")
        }
        return result.trimmingCharacters(in: .whitespaces)
    }
}

enum LRCParser {
    private static let tag = try! NSRegularExpression(pattern: #"\[(\d{1,3}):(\d{1,2}(?:[.:]\d{1,3})?)\]"#)

    static func parse(_ lrc: String) -> [LyricLine] {
        var entries: [(Double, String)] = []
        for raw in lrc.components(separatedBy: .newlines) {
            let ns = raw as NSString
            let matches = tag.matches(in: raw, range: NSRange(location: 0, length: ns.length))
            guard let last = matches.last else { continue }
            let text = ns.substring(from: last.range.location + last.range.length).trimmingCharacters(in: .whitespaces)
            for match in matches {
                let minutes = Double(ns.substring(with: match.range(at: 1))) ?? 0
                let seconds = Double(ns.substring(with: match.range(at: 2)).replacingOccurrences(of: ":", with: ".")) ?? 0
                entries.append((minutes * 60 + seconds, text))
            }
        }
        return entries
            .sorted { $0.0 < $1.0 }
            .enumerated()
            .map { LyricLine(id: $0.offset, time: $0.element.0, text: $0.element.1) }
    }
}

enum DiskCache {
    private static let directory: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("LockPlayer/lyrics", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static func file(_ key: String) -> URL {
        let hash = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("\(hash).json")
    }

    static func load(_ key: String) -> CachedLyrics? {
        guard let data = try? Data(contentsOf: file(key)) else { return nil }
        return try? JSONDecoder().decode(CachedLyrics.self, from: data)
    }

    static func save(_ value: CachedLyrics, for key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: file(key), options: .atomic)
    }
}
