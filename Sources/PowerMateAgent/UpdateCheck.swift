import Foundation
import AppKit

// MARK: - Version

let kCurrentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.10"

// MARK: - Update check

/// Returns true if `version` is strictly newer than `current` (semantic comparison).
private func isNewerVersion(_ version: String, than current: String) -> Bool {
    let a = version.split(separator: ".").compactMap { Int($0) }
    let b = current.split(separator: ".").compactMap { Int($0) }
    for i in 0..<max(a.count, b.count) {
        let av = i < a.count ? a[i] : 0
        let bv = i < b.count ? b[i] : 0
        if av > bv { return true }
        if av < bv { return false }
    }
    return false
}

/// Fetch the latest GitHub release tag and show the update menu item if a newer version exists.
func checkForUpdates() {
    guard let url = URL(string: "https://api.github.com/repos/jameslockman/Griffin-PowerMate-Driver/releases/latest") else { return }
    var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    URLSession.shared.dataTask(with: request) { data, _, _ in
        guard let data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tagName = json["tag_name"] as? String else { return }
        let latest = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
        guard isNewerVersion(latest, than: kCurrentVersion) else { return }
        DispatchQueue.main.async {
            updateAvailableItem.title = "Update available: \(latest) →"
            updateAvailableItem.isHidden = false
        }
    }.resume()
}
