import Foundation
import WidgetKit

// MARK: - Shared models

/// Connection details the app hands to the widget. The widget only ever uses an
/// API key (never the app's login tokens), so it can't disturb the app's session.
struct SureWidgetConfig: Codable, Sendable {
    var baseUrl: String
    var headers: [String: String]
    var apiKey: String?
    var generation: Int?
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
    /// Server-formatted net worth from /api/v1/balance_sheet.
    var netWorth: String?
    var generation: Int?
}

// MARK: - App Group storage

/// Finds the shared App Group container and reads/writes the widget files.
///
/// Re-signing tools such as AltStore and SideStore rename the App Group and
/// record the new name under `ALTAppGroups`, so that is checked before the
/// group configured in Info.plist.
///
/// Logging out bumps a shared generation number before deleting the files.
/// Files stamped with an older generation are ignored, so a write that was
/// already in flight at logout can't bring the old account's data back. Keep
/// this in sync with WidgetBridge in the Runner target.
enum SureWidgetStore {
    static let baseGroup = "group.am.sure.mobile"

    private static let configFile = "sure-widget-config.json"
    private static let snapshotFile = "sure-widget-snapshot.json"
    private static let generationFile = "sure-widget-generation.json"

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

    static func currentGeneration() -> Int {
        guard let url = containerURL()?.appendingPathComponent(generationFile),
              let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return 0 }
        return object["generation"] as? Int ?? 0
    }

    static func loadConfig() -> SureWidgetConfig? {
        guard let config = read(SureWidgetConfig.self, from: configFile),
              (config.generation ?? 0) == currentGeneration() else { return nil }
        return config
    }

    static func loadSnapshot() -> SureWidgetSnapshot? {
        guard let snapshot = read(SureWidgetSnapshot.self, from: snapshotFile),
              (snapshot.generation ?? 0) == currentGeneration() else { return nil }
        return snapshot
    }

    /// Saves a snapshot unless the user logged out since it was fetched. The
    /// snapshot keeps its generation, so even a save that races a logout is
    /// ignored by `loadSnapshot` afterwards.
    static func saveSnapshot(_ snapshot: SureWidgetSnapshot) {
        guard (snapshot.generation ?? 0) == currentGeneration() else { return }
        write(snapshot, to: snapshotFile)
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

    /// Fetches the server-computed net worth. Returns nil if it can't be loaded,
    /// so the widget hides net worth rather than showing a stale or local sum.
    static func fetchNetWorth(config: SureWidgetConfig) async -> String? {
        guard let apiKey = config.apiKey, !apiKey.isEmpty else { return nil }
        let base = config.baseUrl.hasSuffix("/") ? String(config.baseUrl.dropLast()) : config.baseUrl
        guard let url = URL(string: "\(base)/api/v1/balance_sheet") else { return nil }

        var request = URLRequest(url: url, timeoutInterval: 15)
        for (name, value) in config.headers { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue(apiKey, forHTTPHeaderField: "X-Api-Key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        guard let result = try? await URLSession(configuration: .ephemeral).data(for: request),
              (result.1 as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode(BalanceSheetResponse.self, from: result.0) else { return nil }
        return decoded.netWorth?.formatted
    }

    /// Fetches fresh balances and stores them. Returns the snapshot to show plus
    /// whether it is live (false = fell back to the last saved numbers).
    static func refreshSnapshot() async -> (snapshot: SureWidgetSnapshot?, isLive: Bool, needsSetup: Bool) {
        let generation = SureWidgetStore.currentGeneration()
        let saved = SureWidgetStore.loadSnapshot()
        guard let config = SureWidgetStore.loadConfig(), config.apiKey?.isEmpty == false else {
            return (saved, false, true)
        }
        do {
            let accounts = try await fetchAccounts(config: config)
            let netWorth = await fetchNetWorth(config: config)
            // The user logged out while this was fetching: drop the result.
            guard SureWidgetStore.currentGeneration() == generation else { return (nil, false, true) }
            let snapshot = SureWidgetSnapshot(updatedAt: Date(), accounts: accounts,
                                              netWorth: netWorth, generation: generation)
            SureWidgetStore.saveSnapshot(snapshot)
            return (snapshot, true, false)
        } catch {
            // Same check on failure: after a logout, don't fall back to the
            // previous account's saved balances.
            guard SureWidgetStore.currentGeneration() == generation else { return (nil, false, true) }
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

private struct BalanceSheetResponse: Decodable {
    struct MoneyValue: Decodable { let formatted: String? }
    let netWorth: MoneyValue?
    enum CodingKeys: String, CodingKey { case netWorth = "net_worth" }
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
