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
  private var sessionGeneration = 0
  private var chatGeneration = 0

  func restoreSession() async {
    let generation = sessionGeneration
    baseURLString = UserDefaults.standard.string(forKey: "sure.baseURL") ?? "https://demo.sure.am"
    guard let key = KeychainStore.readAPIKey(), !key.isEmpty,
          let url = normalizedURL(baseURLString) else { return }
    await client.update(baseURL: url, apiKey: key)
    guard sessionGeneration == generation else { return }
    do {
      let balance: BalanceSheet = try await client.get("api/v1/balance_sheet")
      guard sessionGeneration == generation else { return }
      balanceSheet = balance
      isConfigured = true
      await refreshAll()
    } catch {
      guard sessionGeneration == generation else { return }
      errorMessage = "Your saved connection needs attention. \(error.localizedDescription)"
    }
  }

  func connect(baseURL: String, apiKey: String) async -> Bool {
    guard let url = normalizedURL(baseURL) else {
      errorMessage = "Enter a valid HTTPS server address."
      return false
    }
    sessionGeneration &+= 1
    chatGeneration &+= 1
    let generation = sessionGeneration
    isLoading = true
    errorMessage = nil
    await client.update(baseURL: url, apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
    guard sessionGeneration == generation else { return false }
    do {
      let balance: BalanceSheet = try await client.get("api/v1/balance_sheet")
      guard sessionGeneration == generation else { return false }
      balanceSheet = balance
      try KeychainStore.saveAPIKey(apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
      baseURLString = url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
      UserDefaults.standard.set(baseURLString, forKey: "sure.baseURL")
      isConfigured = true
      isLoading = false
      await refreshAll()
      return sessionGeneration == generation
    } catch {
      guard sessionGeneration == generation else { return false }
      errorMessage = error.localizedDescription
      isLoading = false
      return false
    }
  }

  func disconnect() async {
    sessionGeneration &+= 1
    chatGeneration &+= 1
    await unregisterPushToken()
    KeychainStore.deleteAPIKey()
    UserDefaults.standard.removeObject(forKey: "sure.pushSubscriptionID")
    UserDefaults.standard.set(false, forKey: "sure.insightNotifications")
    isConfigured = false
    isLoading = false
    isAssistantThinking = false
    errorMessage = nil
    balanceSheet = nil
    accounts = []
    budgets = []
    insights = []
    chats = []
    selectedChat = nil
    messages = []
  }

  func refreshAll() async {
    let generation = sessionGeneration
    isLoading = true
    errorMessage = nil
    async let balanceRequest: BalanceSheet = client.get("api/v1/balance_sheet")
    async let accountsRequest = loadAllPages(
      path: "api/v1/accounts",
      collection: AccountCollection.self,
      items: \.accounts
    )
    async let budgetsRequest = loadAllPages(
      path: "api/v1/budgets",
      collection: BudgetCollection.self,
      items: \.budgets
    )
    do {
      let (balance, loadedAccounts, loadedBudgets) = try await (
        balanceRequest,
        accountsRequest,
        budgetsRequest
      )
      guard sessionGeneration == generation else { return }
      balanceSheet = balance
      accounts = loadedAccounts
      budgets = loadedBudgets
    } catch {
      guard sessionGeneration == generation else { return }
      errorMessage = error.localizedDescription
      isLoading = false
      return
    }

    do {
      let loadedChats = try await loadAllPages(
        path: "api/v1/chats",
        collection: ChatCollection.self,
        items: \.chats
      )
      guard sessionGeneration == generation else { return }
      chats = loadedChats
    } catch let error as SureAPIError {
      guard sessionGeneration == generation else { return }
      if case .server(status: 403, message: _) = error {
        chats = []
      } else {
        errorMessage = error.localizedDescription
      }
    } catch {
      guard sessionGeneration == generation else { return }
      errorMessage = error.localizedDescription
    }

    await loadInsights()
    guard sessionGeneration == generation else { return }
    if UserDefaults.standard.bool(forKey: "sure.insightNotifications") {
      if let token = UserDefaults.standard.string(forKey: "sure.apnsDeviceToken") {
        await registerPushToken(token)
      }
    } else {
      await unregisterPushToken()
    }
    guard sessionGeneration == generation else { return }
    isLoading = false
  }

  func loadInsights() async {
    let generation = sessionGeneration
    do {
      let collection: InsightCollection = try await client.get("api/v1/insights")
      guard sessionGeneration == generation else { return }
      insights = collection.insights
    } catch let error as SureAPIError {
      guard sessionGeneration == generation else { return }
      if case .server(status: 404, message: _) = error {
        insights = makeLocalInsights()
      } else if case .server(status: 403, message: _) = error {
        insights = []
      } else {
        errorMessage = error.localizedDescription
      }
    } catch {
      guard sessionGeneration == generation else { return }
      errorMessage = error.localizedDescription
    }
  }

  func loadChat(_ chat: SureChat) async {
    chatGeneration &+= 1
    let generation = sessionGeneration
    let conversationGeneration = chatGeneration
    selectedChat = chat
    isAssistantThinking = false
    do {
      let detail = try await loadLatestChatDetail(chatID: chat.id)
      guard sessionGeneration == generation,
            chatGeneration == conversationGeneration,
            selectedChat?.id == chat.id else { return }
      messages = detail.messages.sorted { $0.createdAt < $1.createdAt }
    } catch {
      guard sessionGeneration == generation, chatGeneration == conversationGeneration else { return }
      errorMessage = error.localizedDescription
    }
  }

  func newChat() {
    chatGeneration &+= 1
    selectedChat = nil
    messages = []
    isAssistantThinking = false
  }

  func sendMessage(_ content: String) async {
    let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, !isAssistantThinking else { return }
    let generation = sessionGeneration
    let conversationGeneration = chatGeneration
    isAssistantThinking = true
    errorMessage = nil
    do {
      if let selectedChat {
        let request = MessageRequest(content: text)
        let _: MessageReceipt = try await client.post(
          "api/v1/chats/\(selectedChat.id)/messages",
          body: request
        )
        guard sessionGeneration == generation, chatGeneration == conversationGeneration else { return }
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
        guard sessionGeneration == generation, chatGeneration == conversationGeneration else { return }
        selectedChat = detail.chat
        messages = detail.messages.sorted { $0.createdAt < $1.createdAt }
      }
      try await pollForAssistantResponse(
        sessionGeneration: generation,
        chatGeneration: conversationGeneration
      )
      guard sessionGeneration == generation, chatGeneration == conversationGeneration else { return }
      let loadedChats = try await loadAllPages(
        path: "api/v1/chats",
        collection: ChatCollection.self,
        items: \.chats
      )
      guard sessionGeneration == generation, chatGeneration == conversationGeneration else { return }
      chats = loadedChats
    } catch {
      guard sessionGeneration == generation, chatGeneration == conversationGeneration else { return }
      errorMessage = error.localizedDescription
    }
    guard sessionGeneration == generation, chatGeneration == conversationGeneration else { return }
    isAssistantThinking = false
  }

  func registerPushToken(_ token: String) async {
    guard isConfigured, UserDefaults.standard.bool(forKey: "sure.insightNotifications") else { return }
    let generation = sessionGeneration
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
      guard sessionGeneration == generation else {
        try? await client.delete("api/v1/push_subscriptions/\(receipt.id)")
        return
      }
      UserDefaults.standard.set(receipt.id, forKey: "sure.pushSubscriptionID")
    } catch let error as SureAPIError {
      guard sessionGeneration == generation else { return }
      if case .server(status: 404, message: _) = error { return }
      errorMessage = error.localizedDescription
    } catch {
      guard sessionGeneration == generation else { return }
      errorMessage = error.localizedDescription
    }
  }

  func unregisterPushToken() async {
    guard isConfigured,
          let id = UserDefaults.standard.string(forKey: "sure.pushSubscriptionID") else { return }
    let generation = sessionGeneration
    do {
      try await client.delete("api/v1/push_subscriptions/\(id)")
      guard sessionGeneration == generation else { return }
      UserDefaults.standard.removeObject(forKey: "sure.pushSubscriptionID")
    } catch let error as SureAPIError {
      guard sessionGeneration == generation else { return }
      if case .server(status: 404, message: _) = error {
        UserDefaults.standard.removeObject(forKey: "sure.pushSubscriptionID")
        return
      }
      errorMessage = error.localizedDescription
    } catch {
      guard sessionGeneration == generation else { return }
      errorMessage = error.localizedDescription
    }
  }

  private func pollForAssistantResponse(sessionGeneration: Int, chatGeneration: Int) async throws {
    guard let chat = selectedChat else { return }
    let previousAssistantIDs = Set(messages.filter { !$0.isUser }.map(\.id))
    let retryDelays = [3, 5, 8, 13, 21, 34]
    for delay in retryDelays {
      try await Task.sleep(for: .seconds(delay))
      guard self.sessionGeneration == sessionGeneration,
            self.chatGeneration == chatGeneration,
            !Task.isCancelled else { return }
      let detail: ChatDetail
      do {
        detail = try await loadLatestChatDetail(chatID: chat.id)
      } catch let error as SureAPIError {
        if case .server(status: 429, message: _) = error {
          throw error
        }
        continue
      } catch {
        continue
      }
      guard self.sessionGeneration == sessionGeneration,
            self.chatGeneration == chatGeneration else { return }
      messages = detail.messages.sorted { $0.createdAt < $1.createdAt }
      if messages.contains(where: { !$0.isUser && !previousAssistantIDs.contains($0.id) && !$0.content.isEmpty }) {
        return
      }
    }
    guard self.sessionGeneration == sessionGeneration, self.chatGeneration == chatGeneration else { return }
    errorMessage = "The assistant is still working. Pull to refresh this conversation in a moment."
  }

  private func loadAllPages<Collection: Decodable & Sendable, Item: Sendable>(
    path: String,
    collection: Collection.Type,
    items: KeyPath<Collection, [Item]>
  ) async throws -> [Item] where Collection: PaginatedCollection {
    let firstPage = try await client.get("\(path)?page=1&per_page=100", as: collection)
    var allItems = firstPage[keyPath: items]
    let totalPages = firstPage.pagination?.totalPages ?? 1
    guard totalPages > 1 else { return allItems }

    for page in 2...totalPages {
      let nextPage = try await client.get("\(path)?page=\(page)&per_page=100", as: collection)
      allItems.append(contentsOf: nextPage[keyPath: items])
    }
    return allItems
  }

  private func loadLatestChatDetail(chatID: String) async throws -> ChatDetail {
    let firstPage: ChatDetail = try await client.get("api/v1/chats/\(chatID)")
    guard let pagination = firstPage.pagination,
          pagination.totalPages > pagination.page else { return firstPage }

    return try await client.get("api/v1/chats/\(chatID)?page=\(pagination.totalPages)")
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

protocol PaginatedCollection {
  var pagination: SurePagination? { get }
}

extension AccountCollection: PaginatedCollection {}
extension BudgetCollection: PaginatedCollection {}
extension ChatCollection: PaginatedCollection {}

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
