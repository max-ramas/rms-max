// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Maksim Ramzaev. Part of RMS MAKS; see LICENSE.

import Foundation

public extension AppStore {
    static let autoUpdateKey = "rmsmaks.updates.auto"
    private static let lastCheckKey = "rmsmaks.updates.lastCheck"

    /// Default on: only a GET of the public catalog, nothing about the user is sent.
    var autoUpdateCheck: Bool {
        get { UserDefaults.standard.object(forKey: Self.autoUpdateKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.autoUpdateKey); objectWillChange.send() }
    }

    /// Called at start-up; checks at most every 12 hours.
    func autoCheckForUpdates() async {
        guard autoUpdateCheck else { return }
        let last = UserDefaults.standard.double(forKey: Self.lastCheckKey)
        guard Date().timeIntervalSince1970 - last > 12 * 3600 else { return }
        await checkForUpdates(manual: false)
    }

    func checkForUpdates(manual: Bool) async {
        updateStatus = manual ? "Проверяем…" : nil
        do {
            availableUpdate = try await AppUpdater.check()
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastCheckKey)
            updateStatus = availableUpdate == nil ? (manual ? "Установлена последняя версия" : nil) : nil
        } catch {
            updateStatus = manual ? error.localizedDescription : nil
        }
    }

    #if os(macOS)
    func installAvailableUpdate() async {
        guard let update = availableUpdate else { return }
        isInstallingUpdate = true
        updateStatus = "Загрузка и проверка \(update.version)…"
        do {
            try await AppUpdater.install(update) // quits the app on success
        } catch {
            isInstallingUpdate = false
            updateStatus = error.localizedDescription
        }
    }
    #endif
}
