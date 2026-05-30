import Foundation
import Sentry
import PostHog
import os

enum Analytics {
    private static let log = StenoLog.app

    // Public-by-design SDK keys (see docs/adr/0009-build-time-config-for-sdk-keys.md).
    // Stored in Steno.xcconfig (gitignored) and plumbed via Info.plist at build time.
    // Empty strings when running tests or a build without the xcconfig — SDK init becomes a no-op.
    private static let sentryDSN: String =
        Bundle.main.infoDictionary?["SentryDSN"] as? String ?? ""
    private static let posthogAPIKey: String =
        Bundle.main.infoDictionary?["PostHogKey"] as? String ?? ""
    private static let posthogHost = "https://us.i.posthog.com"

    private static let locale = Locale.current.identifier

    // MARK: - Init

    static func configure() {
        if sentryDSN.isEmpty {
            log.info("Sentry DSN missing — skipping Sentry init (likely a build without Steno.xcconfig)")
        } else {
            SentrySDK.start { options in
                options.dsn = sentryDSN
                options.enableAutoSessionTracking = true
                options.enableCaptureFailedRequests = false
                options.enableNetworkBreadcrumbs = false
                options.sendDefaultPii = false
                options.beforeSend = { event in
                    UserDefaults.standard.bool(forKey: "enableCrashReporting") ? event : nil
                }
            }
        }

        if posthogAPIKey.isEmpty {
            log.info("PostHog key missing — skipping PostHog init (likely a build without Steno.xcconfig)")
        } else {
            let config = PostHogConfig(apiKey: posthogAPIKey, host: posthogHost)
            config.captureApplicationLifecycleEvents = false
            config.captureScreenViews = false
            config.sendFeatureFlagEvent = false
            PostHogSDK.shared.setup(config)
            syncPostHogOptOut()
        }

        log.info("Analytics configured")
    }

    static func syncPostHogOptOut() {
        if UserDefaults.standard.bool(forKey: "enableAnalytics") {
            PostHogSDK.shared.optIn()
        } else {
            PostHogSDK.shared.optOut()
        }
    }

    // MARK: - Events

    static func recordingStopped(duration: TimeInterval, model: String) {
        PostHogSDK.shared.capture("recording_stopped", properties: [
            "duration_seconds": Int(duration),
            "model": model,
            "locale": locale,
        ])
    }

    static func importTranscribed(duration: TimeInterval, model: String) {
        PostHogSDK.shared.capture("import_transcribed", properties: [
            "duration_seconds": Int(duration),
            "model": model,
            "locale": locale,
        ])
    }

    static func retranscribeCompleted(duration: TimeInterval, model: String) {
        PostHogSDK.shared.capture("retranscribe_completed", properties: [
            "duration_seconds": Int(duration),
            "model": model,
            "locale": locale,
        ])
    }

    // MARK: - Errors

    static func captureError(_ error: Error, context: [String: String] = [:]) {
        SentrySDK.capture(error: error) { scope in
            for (key, value) in context {
                scope.setExtra(value: value, key: key)
            }
        }
    }

    static func sessionRecovered(sessionID: String) {
        SentrySDK.capture(message: "Session recovered after crash") { scope in
            scope.setExtra(value: sessionID, key: "session_id")
        }
    }
}
