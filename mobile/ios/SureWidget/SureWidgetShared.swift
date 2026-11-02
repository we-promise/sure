import Foundation
import WidgetKit

// MARK: - Shared models

/// Connection details the app hands to the widget. The widget only ever uses an
/// API key (never the app's login tokens), so it can't disturb the app's session.
struct SureWidgetConfig: Codable, Sendable {
    var baseUrl: String
    var headers: [String: String]
    var apiKey: String?
}

struct SureWidgetAccount: Codable, Sendable, Identifiable, Hashable {
    var id: String
    var name: String
    /// Server-formatted balance, e.g. "$1,234.56".
    var balance: String
    var balanceCents: Int?
    var currency: String
    var classification: String?
    var accountType: String?
    var institutionName: String?

    var isLiability: Bool { classification == "liability" }
}

struct SureWidgetSnapshot: Codable, Sendable {
    var updatedAt: Date
    var accounts: [SureWidgetAccount]
}

// MARK: - App Group storage

/// Finds the shared App Group container and reads/writes the widget files.
///
/// Re-signing tools such as AltStore and SideStore rename the App Group and
/// record the new name under `ALTAppGroups`, so that is checked before the
/// group configured in Info.plist.
enum SureWidgetStore {
    static let baseGroup = "group.am.sure.mobile"

    private static let configFile = "sure-widget-config.json"
    private static let snapshotFile = "sure-widget-snapshot.json"

    static func candidateGroups() -> [String] {
        var groups: [String] = []
        let info = Bundle.main.infoDictionary ?? [:]
        if let alt = info["ALTAppGroups"] as? [String] { groups += alt }
        if let configured = info["SureAppGroup"] as? String { groups.append(configured) }
        groups.append(baseGroup)

        var seen = Set<String>()
        return groups.filter { seen.insert($0).inserted }
    }

    static func containerURL() -> URL? {
        for group in candidateGroups() {
            if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) {
                return url
            }
        }
        return nil
    }

    static func loadConfig() -> SureWidgetConfig? { read(SureWidgetConfig.self, from: configFile) }
    static func loadSnapshot() -> SureWidgetSnapshot? { read(SureWidgetSnapshot.self, from: snapshotFile) }

    static func saveConfig(_ config: SureWidgetConfig) { write(config, to: configFile) }
    static func saveSnapshot(_ snapshot: SureWidgetSnapshot) { write(snapshot, to: snapshotFile) }

    static func clear() {
        guard let dir = containerURL() else { return }
        for name in [configFile, snapshotFile] {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
    }

    private static func read<T: Decodable>(_ type: T.Type, from name: String) -> T? {
        guard let url = containerURL()?.appendingPathComponent(name),
              let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: data)
    }

    private static func write<T: Encodable>(_ value: T, to name: String) {
        guard let url = containerURL()?.appendingPathComponent(name) else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value) else { return }
        // Readable after the first unlock since boot, so the widget can refresh
        // while the phone is locked; still encrypted before that.
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

// MARK: - Sure API

enum SureWidgetFetchError: Error {
    case notConfigured
    case badURL
    case unauthorized
    case http(Int)
}

enum SureWidgetAPI {
    /// Fetches every account from the Sure server with the widget's API key.
    static func fetchAccounts(config: SureWidgetConfig) async throws -> [SureWidgetAccount] {
        guard let apiKey = config.apiKey, !apiKey.isEmpty else { throw SureWidgetFetchError.notConfigured }

        let base = config.baseUrl.hasSuffix("/") ? String(config.baseUrl.dropLast()) : config.baseUrl
        var accounts: [SureWidgetAccount] = []
        var page = 1
        var totalPages = 1

        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.timeoutIntervalForRequest = 15
        sessionConfig.timeoutIntervalForResource = 25
        let session = URLSession(configuration: sessionConfig)

        while page <= totalPages && page <= 10 {
            guard let url = URL(string: "\(base)/api/v1/accounts?page=\(page)&per_page=100") else {
                throw SureWidgetFetchError.badURL
            }
            var request = URLRequest(url: url)
            for (name, value) in config.headers { request.setValue(value, forHTTPHeaderField: name) }
            request.setValue(apiKey, forHTTPHeaderField: "X-Api-Key")
            request.setValue("application/json", forHTTPHeaderField: "Accept")

            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 { throw SureWidgetFetchError.unauthorized }
            guard status == 200 else { throw SureWidgetFetchError.http(status) }

            let decoded = try JSONDecoder().decode(AccountsResponse.self, from: data)
            accounts += decoded.accounts
                .filter { $0.status == nil || $0.status == "active" }
                .map(\.widgetAccount)
            totalPages = decoded.pagination?.totalPages ?? 1
            page += 1
        }
        return accounts
    }

    /// Fetches fresh balances and stores them. Returns the snapshot to show plus
    /// whether it is live (false = fell back to the last saved numbers).
    static func refreshSnapshot() async -> (snapshot: SureWidgetSnapshot?, isLive: Bool, needsSetup: Bool) {
        let saved = SureWidgetStore.loadSnapshot()
        guard let config = SureWidgetStore.loadConfig(), config.apiKey?.isEmpty == false else {
            return (saved, false, true)
        }
        do {
            let accounts = try await fetchAccounts(config: config)
            let snapshot = SureWidgetSnapshot(updatedAt: Date(), accounts: accounts)
            SureWidgetStore.saveSnapshot(snapshot)
            return (snapshot, true, false)
        } catch {
            return (saved, false, false)
        }
    }
}

private struct AccountsResponse: Decodable {
    struct Pagination: Decodable {
        let totalPages: Int?
        enum CodingKeys: String, CodingKey { case totalPages = "total_pages" }
    }

    struct APIAccount: Decodable {
        let id: LossyString
        let name: String
        let balance: String
        let balanceCents: Int?
        let currency: String
        let classification: String?
        let accountType: String?
        let status: String?
        let institutionName: String?

        enum CodingKeys: String, CodingKey {
            case id, name, balance, currency, classification, status
            case balanceCents = "balance_cents"
            case accountType = "account_type"
            case institutionName = "institution_name"
        }

        var widgetAccount: SureWidgetAccount {
            SureWidgetAccount(
                id: id.value, name: name, balance: balance, balanceCents: balanceCents,
                currency: currency, classification: classification,
                accountType: accountType, institutionName: institutionName
            )
        }
    }

    let accounts: [APIAccount]
    let pagination: Pagination?
}

/// Accepts an ID that may arrive as a string or a number.
private struct LossyString: Decodable {
    let value: String
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { value = s }
        else if let i = try? c.decode(Int.self) { value = String(i) }
        else { value = "" }
    }
}
