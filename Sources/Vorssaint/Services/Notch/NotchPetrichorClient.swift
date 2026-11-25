// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// Reads Petrichor's sandbox snapshot while that app is Now Playing.
final class NotchPetrichorClient {
    static let shared = NotchPetrichorClient()
    private var observer: NSObjectProtocol?
    private var playback: NotchPlayback?
    private var notifiedPath: String?

    private init() {}

    func install() {
        NotchPetrichorSupport.observePlayback = { [weak self] in self?.observe($0) }
    }

    func reload() {
        guard let playback, NotchPetrichorSupport.owns(playback) else { return }
        apply(path: notifiedPath, playback: playback)
    }

    private func observe(_ playback: NotchPlayback?) {
        guard NotchPetrichorSupport.owns(playback), let playback else {
            stop()
            return
        }
        self.playback = playback
        if observer == nil {
            observer = DistributedNotificationCenter.default().addObserver(
                forName: NotchPetrichorSupport.stateChanged, object: nil, queue: .main
            ) { [weak self] notification in
                self?.received(notification)
            }
        }
        apply(path: notifiedPath, playback: playback)
    }

    private func received(_ notification: Notification) {
        guard let playback, NotchPetrichorSupport.owns(playback) else { return }
        let announced = notification.userInfo?["bundleIdentifier"] as? String
        if let announced, !NotchPetrichorSupport.bundles.contains(announced) { return }
        notifiedPath = NotchPetrichorSupport.notifiedPath(from: notification.userInfo)
        apply(path: notifiedPath, playback: playback)
    }

    private func apply(path: String?, playback: NotchPlayback) {
        guard let bundle = playback.track.appBundleIdentifier else { return }
        let urls = NotchPetrichorSupport.candidateURLs(
            bundleIdentifier: bundle,
            home: FileManager.default.homeDirectoryForCurrentUser,
            notifiedPath: path)
        guard let data = urls.lazy.compactMap({ try? Data(contentsOf: $0) }).first(where: { $0.count <= NotchPetrichorSupport.maximumBytes }),
              let snapshot = NotchPetrichorSupport.decode(data) else {
            NotchMusicService.shared.petrichorSnapshotUnavailable()
            return
        }
        if let lyrics = NotchPetrichorSupport.lyrics(from: snapshot) {
            NotchLyricsService.shared.applyExternal(lyrics, for: playback)
        }
        NotchMusicService.shared.applyPetrichorSnapshot(snapshot)
    }

    private func stop() {
        if let observer {
            DistributedNotificationCenter.default().removeObserver(observer)
            self.observer = nil
        }
        playback = nil
        notifiedPath = nil
    }
}
