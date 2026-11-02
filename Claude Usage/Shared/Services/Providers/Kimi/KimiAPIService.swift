import Foundation
import CoreFoundation

/// Reads Kimi Code quota data only. Requests never generate model usage.
@MainActor
final class KimiAPIService {
    typealias Transport = (URLRequest) async throws -> (Data, HTTPURLResponse)
    private let transport: Transport
    private let now: () -> Date
    private struct Account: Hashable { let key: String; let region: KimiRegion }
    private struct RetryState { var failures = 0; var until = Date.distantPast }
    private var retries: [Account: RetryState] = [:]
    private static let session = URLSession(configuration: .ephemeral,
        delegate: KimiRedirectBlocker(), delegateQueue: nil)

    init(now: @escaping () -> Date = Date.init, transport: Transport? = nil) {
        self.now = now
        self.transport = transport ?? { request in
            let (data, response) = try await Self.session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw KimiError.invalidResponse }
            return (data, response)
        }
    }

    func fetchUsage(apiKey: String, region: KimiRegion) async throws -> KimiUsage {
        guard let key = apiKey.nilIfBlank, !key.contains(where: { $0.isWhitespace || $0.isNewline }) else {
            throw AppError(code: .providerCredentialsNotFound, message: "kimi.error.key".localized, isRecoverable: true)
        }
        let account = Account(key: key, region: region)
        guard (retries[account]?.until ?? .distantPast) <= now() else { throw KimiError.retryLater }
        var request = URLRequest(url: region.usageURL)
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Claude-Usage-Tracker/3.3.0", forHTTPHeaderField: "User-Agent")
        let data: Data
        let response: HTTPURLResponse
        do { (data, response) = try await transport(request) }
        catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            backoff(account)
            throw AppError(code: .networkGenericError, message: "kimi.error.network".localized, isRecoverable: true)
        }
        try Task.checkCancellation()
        if response.statusCode == 401 || response.statusCode == 403 {
            backoff(account)
            throw AppError(code: .providerAuthExpired, message: "kimi.error.key".localized, isRecoverable: true)
        }
        if response.statusCode == 429 || response.statusCode == 503 {
            backoff(account, retryAfter: response.value(forHTTPHeaderField: "Retry-After"))
            throw KimiError.retryLater
        }
        guard (200...299).contains(response.statusCode) else {
            backoff(account)
            throw AppError(code: .networkGenericError, message: "kimi.error.network".localized, isRecoverable: true)
        }
        do {
            let usage = try Self.parse(data: data, fetchedAt: now())
            retries.removeValue(forKey: account)
            return usage
        } catch {
            backoff(account)
            throw KimiError.invalidResponse
        }
    }

    private func backoff(_ account: Account, retryAfter: String? = nil) {
        var state = retries[account] ?? RetryState()
        state.failures = min(state.failures + 1, 6)
        var delay = min(15 * pow(2, Double(state.failures - 1)), 300)
        if let raw = retryAfter {
            if let seconds = Double(raw), seconds.isFinite, seconds > 0 {
                delay = max(delay, seconds)
            } else {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
                if let date = formatter.date(from: raw) { delay = max(delay, date.timeIntervalSince(now())) }
            }
        }
        state.until = now().addingTimeInterval(delay)
        retries[account] = state
    }

    /// Mirrors Kimi's own managed-usage parser. Unknown/malformed windows are
    /// omitted, rather than turning missing data into a fresh zero-percent sample.
    static func parse(data: Data, fetchedAt: Date) throws -> KimiUsage {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["error"] == nil else { throw KimiError.invalidResponse }
        let named = root["usages"] as? [String: Any] ?? [:]
        let definitions: [(String, String, UsageQuota.Role, Int?, String)] = [
            ("limit_5h", "kimi.quota.session", .session, 300, "widget.session"),
            ("limit_7d", "kimi.quota.weekly", .weekly, 10080, "widget.weekly"),
            ("limit_month_total", "kimi.quota.monthly", .other, nil, "widget.monthly"),
            ("limit_month_code", "kimi.quota.code_share", .other, nil, "widget.monthly_code")
        ]
        var quotas: [UsageQuota] = definitions.compactMap { id, label, role, minutes, widgetLabel in
            guard let item = named[id] as? [String: Any],
                  let ratio = number(item["used_ratio"]), ratio >= 0 else { return nil }
            return UsageQuota(id: id, bucketID: "kimi", label: label.localized, role: role,
                usedPercentage: min(ratio * 100, 100), resetTime: date(item["reset_time"]),
                durationMinutes: minutes, widgetLabelKey: widgetLabel)
        }
        // Legacy plans report weekly allowance in `usage` and rolling limits
        // separately. Named ratios take precedence even when they report zero.
        func appendLegacy(_ id: String, _ item: [String: Any]?, _ role: UsageQuota.Role,
                          _ minutes: Int, _ label: String, _ widgetLabel: String) {
            guard named[id] == nil, let item,
                  let limit = number(item["limit"]), limit > 0,
                  let remaining = number(item["remaining"]), remaining >= 0, remaining <= limit else { return }
            quotas.append(UsageQuota(id: id, bucketID: "kimi", label: label.localized, role: role,
                usedPercentage: (limit - remaining) / limit * 100, resetTime: date(item["resetTime"]),
                durationMinutes: minutes, widgetLabelKey: widgetLabel))
        }
        appendLegacy("limit_7d", root["usage"] as? [String: Any], .weekly, 10080,
                     "kimi.quota.weekly", "widget.weekly")
        for item in root["limits"] as? [[String: Any]] ?? [] {
            guard let window = item["window"] as? [String: Any], number(window["duration"]) == 5,
                  let unit = window["timeUnit"] as? String,
                  ["TIME_UNIT_HOUR", "HOUR", "HOURS"].contains(unit.uppercased()) else { continue }
            if !quotas.contains(where: { $0.id == "limit_5h" }) {
                appendLegacy("limit_5h", item["detail"] as? [String: Any], .session, 300,
                             "kimi.quota.session", "widget.session")
            }
        }
        if let total = quotas.first(where: { $0.id == "limit_month_total" }),
           let code = quotas.first(where: { $0.id == "limit_month_code" }), code.usedPercentage > total.usedPercentage {
            quotas.removeAll { $0.id == "limit_month_code" }
        }
        guard !quotas.isEmpty else { throw KimiError.invalidResponse }
        return KimiUsage(quotas: quotas, lastUpdated: fetchedAt)
    }

    private static func number(_ value: Any?) -> Double? {
        let number: Double?
        if let value = value as? NSNumber {
            guard CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
            number = value.doubleValue
        } else if let value = value as? String { number = Double(value) }
        else { return nil }
        guard let number, number.isFinite else { return nil }
        return number
    }

    private static func date(_ value: Any?) -> Date? {
        guard let value = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}

/// A usage endpoint redirect must never forward the subscription credential.
private final class KimiRedirectBlocker: NSObject, URLSessionTaskDelegate {
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
