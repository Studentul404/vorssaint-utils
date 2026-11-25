// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// File and notification contract with Petrichor. Petrichor is sandboxed, so
/// the JSON lives in its container; this process is not sandboxed and reads it
/// only while Petrichor owns Now Playing.
enum NotchPetrichorSupport {
    static let fileName = "vorssaint-bridge.json"
    static let stateChanged = Notification.Name("org.Petrichor.stateChanged")
    static let playQueueIndex = Notification.Name("org.Petrichor.playQueueIndex")
    static let bundles: Set<String> = ["org.Petrichor", "org.Petrichor.debug"]
    static let itemPrefix = "petrichor:"
    static let maximumBytes = 256 * 1024
    /// Production installs the client; tests leave this unset.
    static var observePlayback: ((NotchPlayback?) -> Void)?

    struct Track: Equatable {
        let index: Int
        let title: String
        let artist: String
        let duration: Double
    }

    struct Line: Equatable {
        let time: Double
        let text: String
    }

    struct Lyrics: Equatable {
        let timed: Bool
        let instrumental: Bool
        let plain: String
        let lines: [Line]
    }

    struct Snapshot: Equatable {
        let version: Int
        let bundleIdentifier: String
        let currentIndex: Int
        let current: Track?
        let lyrics: Lyrics?
        let queue: [Track]
    }

    static func owns(_ playback: NotchPlayback?) -> Bool {
        guard let bundle = playback?.track.appBundleIdentifier else { return false }
        return bundles.contains(bundle)
    }

    static func notePlayback(_ playback: NotchPlayback?) {
        observePlayback?(playback)
    }

    static func requestPlay(_ item: NotchQueueItem) -> Bool {
        guard let index = playIndex(from: item) else { return false }
        DistributedNotificationCenter.default().postNotificationName(
            playQueueIndex, object: nil, userInfo: ["index": index], deliverImmediately: true)
        return true
    }

    static func playIndex(from item: NotchQueueItem) -> Int? {
        guard item.id.hasPrefix(itemPrefix) else { return nil }
        let raw = item.id.dropFirst(itemPrefix.count)
        guard let index = Int(raw), index >= 0, index <= 10_000 else { return nil }
        return index
    }

    static func itemIdentifier(index: Int) -> String { itemPrefix + String(index) }

    static func notifiedPath(from userInfo: [AnyHashable: Any]?) -> String? {
        guard let path = userInfo?["path"] as? String, !path.isEmpty, path.utf8.count <= 4096,
              !path.contains("\0"), URL(fileURLWithPath: path).lastPathComponent == fileName else { return nil }
        return path
    }

    static func candidateURLs(bundleIdentifier: String, home: URL,
                              notifiedPath: String? = nil) -> [URL] {
        guard bundles.contains(bundleIdentifier) else { return [] }
        var urls: [URL] = []
        if let notifiedPath { urls.append(URL(fileURLWithPath: notifiedPath)) }
        urls.append(home.appendingPathComponent(
            "Library/Containers/\(bundleIdentifier)/Data/Library/Application Support/\(bundleIdentifier)/\(fileName)"))
        urls.append(home.appendingPathComponent(
            "Library/Application Support/\(bundleIdentifier)/\(fileName)"))
        urls.append(home.appendingPathComponent("Library/Application Support/Petrichor/\(fileName)"))
        var seen = Set<String>()
        return urls.filter { seen.insert($0.path).inserted }
    }

    static func decode(_ data: Data) -> Snapshot? {
        guard data.count <= maximumBytes,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = object["version"] as? Int, version == 1,
              let bundle = object["bundleIdentifier"] as? String, bundles.contains(bundle),
              let currentIndex = int(object["currentIndex"]) else { return nil }
        let queue = tracks(object["queue"])
        guard queue.count <= NotchQueueSelection.maximumItems + 1 else { return nil }
        let current = track(object["current"]) ?? queue.first { $0.index == currentIndex }
        return Snapshot(version: version, bundleIdentifier: bundle, currentIndex: currentIndex,
                        current: current, lyrics: lyrics(object["lyrics"]), queue: queue)
    }

    static func lyrics(from snapshot: Snapshot) -> NotchLyrics? {
        guard let lyrics = snapshot.lyrics else { return nil }
        if lyrics.instrumental {
            return NotchLyrics(lines: [], plain: "", instrumental: true)
        }
        let lines = lyrics.timed ? lyrics.lines.prefix(NotchLyricsSupport.maximumLines).compactMap { line -> NotchLyricLine? in
            guard line.time.isFinite, line.time >= 0, line.text.utf8.count <= 4096 else { return nil }
            return NotchLyricLine(time: line.time, text: line.text)
        } : []
        let plain = lyrics.plain.trimmingCharacters(in: .whitespacesAndNewlines)
        guard lyrics.instrumental || !plain.isEmpty || !lines.isEmpty else { return nil }
        return NotchLyrics(lines: Array(lines), plain: plain, instrumental: false)
    }

    static func queue(from snapshot: Snapshot, playback: NotchPlayback, requestID: UUID) -> NotchQueueSnapshot? {
        guard owns(playback), let pid = playback.track.appPID, pid > 0 else { return nil }
        let currentID = playback.itemIdentifier.flatMap { NotchPlaybackCommand.validIdentifier($0) ? $0 : nil }
            ?? itemIdentifier(index: snapshot.currentIndex)
        guard NotchPlaybackCommand.validIdentifier(currentID) else { return nil }
        var items: [NotchQueueItem] = []
        var offset = 1
        for track in snapshot.queue where track.index > snapshot.currentIndex {
            guard offset <= NotchQueueSelection.maximumItems else { break }
            let title = track.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, title.utf8.count <= 4096 else { continue }
            let duration = track.duration.isFinite ? min(max(0, track.duration), 604_800) : 0
            items.append(NotchQueueItem(id: itemIdentifier(index: track.index), offset: offset,
                                        title: title, artist: String(track.artist.prefix(1024)),
                                        duration: duration))
            offset += 1
        }
        return NotchQueueSnapshot(requestID: requestID, currentIdentifier: currentID, pid: pid,
                                  items: items, canPlay: true)
    }

    private static func tracks(_ value: Any?) -> [Track] {
        guard let rows = value as? [[String: Any]] else { return [] }
        return rows.compactMap(track)
    }

    private static func track(_ value: Any?) -> Track? {
        guard let row = value as? [String: Any], let index = int(row["index"]), index >= 0, index <= 10_000,
              let title = row["title"] as? String, title.utf8.count <= 4096 else { return nil }
        let artist = String((row["artist"] as? String ?? "").prefix(1024))
        let duration = row["duration"] as? Double ?? 0
        guard duration.isFinite, (0...604_800).contains(duration) else { return nil }
        return Track(index: index, title: title, artist: artist, duration: duration)
    }

    private static func lyrics(_ value: Any?) -> Lyrics? {
        guard let object = value as? [String: Any] else { return nil }
        let timed = object["timed"] as? Bool == true
        let instrumental = object["instrumental"] as? Bool == true
        let plain = object["plain"] as? String ?? ""
        guard plain.utf8.count <= maximumBytes / 2 else { return nil }
        let rows = object["lines"] as? [[String: Any]] ?? []
        guard rows.count <= NotchLyricsSupport.maximumLines else { return nil }
        let lines = rows.compactMap { row -> Line? in
            guard let time = row["time"] as? Double, time.isFinite, time >= 0,
                  let text = row["text"] as? String, text.utf8.count <= 4096 else { return nil }
            return Line(time: time, text: text)
        }
        return Lyrics(timed: timed, instrumental: instrumental, plain: plain, lines: lines)
    }

    private static func int(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            return Int(exactly: number.doubleValue)
        }
        return nil
    }
}
