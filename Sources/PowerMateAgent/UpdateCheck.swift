import Foundation
import AppKit

// MARK: - Version

let kCurrentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.10"

// MARK: - Update check

/// Returns true if `version` is strictly newer than `current` (semantic comparison).
private func isNewerVersion(_ version: String, than current: String) -> Bool {
    // Compare the numeric core only. A pre-release suffix such as "1.0.19-holdkey.1" would
    // otherwise split into [1, 0, 1] and make the release it was built from look newer.
    func core(_ s: String) -> [Int] {
        s.split(separator: "-", maxSplits: 1).first.map(String.init)?
            .split(separator: ".").compactMap { Int($0) } ?? []
    }
    let a = core(version)
    let b = core(current)
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
