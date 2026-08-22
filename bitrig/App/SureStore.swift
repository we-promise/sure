import Foundation
import Observation
import UserNotifications
import UIKit

@MainActor
@Observable
final class SureStore {
  var isConfigured = false
  var isLoading = false
  var errorMessage: String?
  var balanceSheet: BalanceSheet?
  var accounts: [SureAccount] = []
  var budgets: [SureBudget] = []
  var insights: [SureInsight] = []
  var chats: [SureChat] = []
  var selectedChat: SureChat?
  var messages: [SureMessage] = []
  var isAssistantThinking = false
  var selectedTab = SureTab.overview

  private(set) var baseURLString = "https://demo.sure.am"
  private var client = SureAPIClient(baseURL: URL(string: "https://demo.sure.am")!, apiKey: "")

  func restoreSession() async {
    baseURLString = UserDefaults.standard.string(forKey: "sure.baseURL") ?? "https://demo.sure.am"
    guard let key = KeychainStore.readAPIKey(), !key.isEmpty,
          let url = normalizedURL(baseURLString) else { return }
    await client.update(baseURL: url, apiKey: key)
    do {
      balanceSheet = try await client.get("api/v1/balance_sheet")
      isConfigured = true
      await refreshAll()
    } catch {
      errorMessage = "Your saved connection needs attention. \(error.localizedDescription)"
    }
  }

  func connect(baseURL: String, apiKey: String) async -> Bool {
    guard let url = normalizedURL(baseURL) else {
      errorMessage = "Enter a valid HTTPS server address."
      return false
    }
    isLoading = true
    errorMessage = nil
    await client.update(baseURL: url, apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
    do {
      balanceSheet = try await client.get("api/v1/balance_sheet")
      try KeychainStore.saveAPIKey(apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
      baseURLString = url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
      UserDefaults.standard.set(baseURLString, forKey: "sure.baseURL")
      isConfigured = true
      isLoading = false
      await refreshAll()
      return true
    } catch {
      errorMessage = error.localizedDescription
      isLoading = false
      return false
    }
  }

  func disconnect() {
    KeychainStore.deleteAPIKey()
    isConfigured = false
    balanceSheet = nil
    accounts = []
    budgets = []
    insights = []
    chats = []
    messages = []
  }

  func refreshAll() async {
    isLoading = true
    errorMessage = nil
    async let balanceRequest: BalanceSheet = client.get("api/v1/balance_sheet")
    async let accountsRequest: AccountCollection = client.get("api/v1/accounts?per_page=100")
    async let budgetsRequest: BudgetCollection = client.get("api/v1/budgets?per_page=100")
    async let chatsRequest: ChatCollection = client.get("api/v1/chats")
    do {
      let (balance, accountCollection, budgetCollection, chatCollection) = try await (
        balanceRequest,
        accountsRequest,
        budgetsRequest,
        chatsRequest
      )
      balanceSheet = balance
      accounts = accountCollection.accounts
      budgets = budgetCollection.budgets
      chats = chatCollection.chats
      await loadInsights()
      if let token = UserDefaults.standard.string(forKey: "sure.apnsDeviceToken") {
        await registerPushToken(token)
      }
    } catch {
      errorMessage = error.localizedDescription
    }
    isLoading = false
  }

  func loadInsights() async {
    do {
      let collection: InsightCollection = try await client.get("api/v1/insights")
      insights = collection.insights
    } catch let error as SureAPIError {
      if case .server(status: 404, message: _) = error {
        insights = makeLocalInsights()
      } else {
        errorMessage = error.localizedDescription
      }
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func loadChat(_ chat: SureChat) async {
    selectedChat = chat
    do {
      let detail: ChatDetail = try await client.get("api/v1/chats/\(chat.id)")
      messages = detail.messages.sorted { $0.createdAt < $1.createdAt }
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func newChat() {
    selectedChat = nil
    messages = []
  }

  func sendMessage(_ content: String) async {
    let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, !isAssistantThinking else { return }
    isAssistantThinking = true
    errorMessage = nil
    do {
      if let selectedChat {
        let request = MessageRequest(content: text)
        let _: MessageReceipt = try await client.post(
          "api/v1/chats/\(selectedChat.id)/messages",
          body: request
        )
        messages.append(SureMessage(
          id: UUID().uuidString,
          type: "user_message",
          role: "user",
          content: text,
          createdAt: ISO8601DateFormatter().string(from: Date())
        ))
      } else {
        let request = NewChatRequest(title: makeTitle(from: text), message: text)
        let detail: ChatDetail = try await client.post("api/v1/chats", body: request)
        selectedChat = detail.chat
        messages = detail.messages.sorted { $0.createdAt < $1.createdAt }
      }
      await pollForAssistantResponse()
      let collection: ChatCollection = try await client.get("api/v1/chats")
      chats = collection.chats
    } catch {
      errorMessage = error.localizedDescription
    }
    isAssistantThinking = false
  }

  func registerPushToken(_ token: String) async {
    guard isConfigured, UserDefaults.standard.bool(forKey: "sure.insightNotifications") else { return }
    let environment = APNsEnvironment.current
    let request = PushSubscriptionRequest(
      token: token,
      environment: environment.rawValue,
      platform: "ios"
    )
    do {
      let receipt: PushSubscriptionReceipt = try await client.post(
        "api/v1/push_subscriptions",
        body: request
      )
      UserDefaults.standard.set(receipt.id, forKey: "sure.pushSubscriptionID")
    } catch let error as SureAPIError {
      if case .server(status: 404, message: _) = error { return }
      errorMessage = error.localizedDescription
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func unregisterPushToken() async {
    guard isConfigured,
          let id = UserDefaults.standard.string(forKey: "sure.pushSubscriptionID") else { return }
    do {
      try await client.delete("api/v1/push_subscriptions/\(id)")
      UserDefaults.standard.removeObject(forKey: "sure.pushSubscriptionID")
    } catch let error as SureAPIError {
      if case .server(status: 404, message: _) = error {
        UserDefaults.standard.removeObject(forKey: "sure.pushSubscriptionID")
        return
      }
      errorMessage = error.localizedDescription
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func pollForAssistantResponse() async {
    guard let chat = selectedChat else { return }
    let previousAssistantIDs = Set(messages.filter { !$0.isUser }.map(\.id))
    for _ in 0..<30 {
      try? await Task.sleep(for: .seconds(2))
      let detail: ChatDetail
      do {
        detail = try await client.get("api/v1/chats/\(chat.id)")
      } catch {
        continue
      }
      messages = detail.messages.sorted { $0.createdAt < $1.createdAt }
      if messages.contains(where: { !$0.isUser && !previousAssistantIDs.contains($0.id) && !$0.content.isEmpty }) {
        return
      }
    }
    errorMessage = "The assistant is still working. Pull to refresh this conversation in a moment."
  }

  private func makeLocalInsights() -> [SureInsight] {
    var generated: [SureInsight] = []
    if let balanceSheet {
      let liabilities = balanceSheet.liabilities.decimalAmount.magnitude
      let assets = balanceSheet.assets.decimalAmount.magnitude
      if liabilities > 0, assets > 0 {
        let ratio = NSDecimalNumber(decimal: liabilities / assets).doubleValue
        generated.append(SureInsight(
          id: "live-debt-ratio",
          type: ratio > 0.5 ? "cash_flow_warning" : "budget_on_track",
          title: ratio > 0.5 ? "Liabilities need attention" : "Your balance sheet looks resilient",
          body: "Liabilities are \((ratio * 100).formatted(.number.precision(.fractionLength(0))))% of assets, based on your live Sure balances.",
          priority: ratio > 0.5 ? "high" : "low",
          status: "active"
        ))
      }
    }
    if let largest = accounts.filter(\.isAsset).max(by: { abs($0.balanceCents) < abs($1.balanceCents) }) {
      generated.append(SureInsight(
        id: "live-largest-account",
        type: "idle_cash",
        title: "Review your largest account",
        body: "\(largest.name) holds \(largest.balance). Ask the Assistant whether that concentration fits your goals.",
        priority: "medium",
        status: "active"
      ))
    }
    if let currentBudget = budgets.first(where: \.current) {
      generated.append(SureInsight(
        id: "live-current-budget",
        type: "budget_on_track",
        title: "Your current plan is ready to review",
        body: "\(currentBudget.name) has \(currentBudget.allocatedSpending) allocated. Check it before the period ends.",
        priority: "low",
        status: "active"
      ))
    }
    return Array(generated.prefix(3))
  }

  private func makeTitle(from content: String) -> String {
    String(content.prefix(48))
  }

  private func normalizedURL(_ input: String) -> URL? {
    guard var components = URLComponents(string: input.trimmingCharacters(in: .whitespacesAndNewlines)),
          components.scheme == "https", components.host != nil else { return nil }
    components.path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/"
    return components.url
  }
}

enum SureTab: Hashable {
  case overview
  case accounts
  case budgets
  case assistant
}

struct NewChatRequest: Codable, Sendable {
  var title: String
  var message: String
}

struct MessageRequest: Codable, Sendable {
  var content: String
}

struct MessageReceipt: Codable, Sendable {
  var id: String
  var chatId: String

  enum CodingKeys: String, CodingKey {
    case id
    case chatId = "chat_id"
  }
}

struct PushSubscriptionRequest: Codable, Sendable {
  var token: String
  var environment: String
  var platform: String
}

struct PushSubscriptionReceipt: Codable, Sendable {
  var id: String
}

enum APNsEnvironment: String {
  case sandbox
  case production

  static var current: APNsEnvironment {
    #if targetEnvironment(simulator)
    return .sandbox
    #else
    guard let profileURL = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
          let profileData = try? Data(contentsOf: profileURL),
          let profileText = String(data: profileData, encoding: .isoLatin1) else {
      return .production
    }
    return profileText.contains("<string>development</string>") ? .sandbox : .production
    #endif
  }
}
