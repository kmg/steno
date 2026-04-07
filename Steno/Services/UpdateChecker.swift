import Foundation
import os

@MainActor
final class UpdateChecker: ObservableObject {
    struct UpdateInfo {
        let version: String
        let url: URL
    }

    @Published var availableUpdate: UpdateInfo?
    @Published var dismissed = false

    private let logger = Logger(subsystem: "com.kmganesh.steno", category: "UpdateChecker")
    private var checkTask: Task<Void, Never>?

    var showBanner: Bool {
        availableUpdate != nil && !dismissed
    }

    func startChecking() {
        checkTask = Task {
            await checkOnce()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(86400))
                guard !Task.isCancelled else { break }
                await checkOnce()
            }
        }
    }

    func dismiss() {
        dismissed = true
    }

    private func checkOnce() async {
        guard let url = URL(string: "https://api.github.com/repos/kmg/steno/releases/latest") else { return }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }

            struct Release: Decodable {
                let tag_name: String
                let html_url: String
            }
            let release = try JSONDecoder().decode(Release.self, from: data)
            let remote = release.tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "v"))
            let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"

            if isNewer(remote: remote, current: current) {
                availableUpdate = UpdateInfo(
                    version: remote,
                    url: URL(string: release.html_url) ?? url
                )
                dismissed = false
                logger.info("Update available: \(remote)")
            }
        } catch {
            logger.debug("Update check skipped: \(error.localizedDescription)")
        }
    }

    private func isNewer(remote: String, current: String) -> Bool {
        let r = remote.split(separator: ".").compactMap { Int($0) }
        let c = current.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(r.count, c.count) {
            let rv = i < r.count ? r[i] : 0
            let cv = i < c.count ? c[i] : 0
            if rv > cv { return true }
            if rv < cv { return false }
        }
        return false
    }
}
