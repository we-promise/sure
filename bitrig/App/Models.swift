import Foundation

struct MoneyValue: Codable, Sendable {
  var amount: String
  var currency: String

  var decimalAmount: Decimal {
    Decimal(string: amount) ?? 0
  }

  var formatted: String {
    decimalAmount.formatted(.currency(code: currency).precision(.fractionLength(0...2)))
  }
}

struct BalanceSheet: Codable, Sendable {
  var currency: String
  var netWorth: MoneyValue
  var assets: MoneyValue
  var liabilities: MoneyValue

  enum CodingKeys: String, CodingKey {
    case currency
    case netWorth = "net_worth"
    case assets
    case liabilities
  }
}

struct SureAccount: Codable, Identifiable, Sendable {
  var id: String
  var name: String
  var balance: String
  var balanceCents: Int
  var cashBalance: String
  var cashBalanceCents: Int
  var currency: String
  var classification: String
  var accountType: String?
  var subtype: String?
  var status: String
  var institutionName: String?

  enum CodingKeys: String, CodingKey {
    case id, name, balance, currency, classification, subtype, status
    case balanceCents = "balance_cents"
    case cashBalance = "cash_balance"
    case cashBalanceCents = "cash_balance_cents"
    case accountType = "account_type"
    case institutionName = "institution_name"
  }

  var isAsset: Bool { classification == "asset" }
}

struct AccountCollection: Codable, Sendable {
  var accounts: [SureAccount]
  var pagination: SurePagination?
}

struct SureBudget: Codable, Identifiable, Sendable {
  var id: String
  var name: String
  var currency: String
  var current: Bool
  var budgetedSpending: String?
  var allocatedSpending: String
  var startDate: String
  var endDate: String

  enum CodingKeys: String, CodingKey {
    case id, name, currency, current
    case budgetedSpending = "budgeted_spending"
    case allocatedSpending = "allocated_spending"
    case startDate = "start_date"
    case endDate = "end_date"
  }
}

struct BudgetCollection: Codable, Sendable {
  var budgets: [SureBudget]
  var pagination: SurePagination?
}

struct SureInsight: Codable, Identifiable, Sendable, Equatable {
  var id: String
  var type: String
  var title: String
  var body: String
  var priority: String
  var status: String
  var generatedAt: String?

  enum CodingKeys: String, CodingKey {
    case id, type, title, body, priority, status
    case generatedAt = "generated_at"
  }

  var symbol: String {
    switch type {
    case "cash_flow_warning", "budget_at_risk": "exclamationmark.triangle.fill"
    case "net_worth_milestone", "budget_on_track": "sparkles"
    case "subscription_audit": "repeat"
    case "idle_cash": "banknote.fill"
    default: "chart.line.uptrend.xyaxis"
    }
  }
}

struct InsightCollection: Codable, Sendable {
  var insights: [SureInsight]
}

struct SureChat: Codable, Identifiable, Sendable, Hashable {
  var id: String
  var title: String
  var error: String?
  var createdAt: String
  var updatedAt: String
  var lastMessageAt: String?
  var messageCount: Int?

  enum CodingKeys: String, CodingKey {
    case id, title, error
    case createdAt = "created_at"
    case updatedAt = "updated_at"
    case lastMessageAt = "last_message_at"
    case messageCount = "message_count"
  }
}

struct ChatCollection: Codable, Sendable {
  var chats: [SureChat]
  var pagination: SurePagination?
}

struct SurePagination: Codable, Sendable {
  var page: Int
  var perPage: Int
  var totalCount: Int
  var totalPages: Int

  enum CodingKeys: String, CodingKey {
    case page
    case perPage = "per_page"
    case totalCount = "total_count"
    case totalPages = "total_pages"
  }
}

struct SureMessage: Codable, Identifiable, Sendable, Equatable {
  var id: String
  var type: String
  var role: String
  var content: String
  var createdAt: String

  enum CodingKeys: String, CodingKey {
    case id, type, role, content
    case createdAt = "created_at"
  }

  var isUser: Bool { role == "user" || type == "user_message" }
}

struct ChatDetail: Codable, Sendable {
  var id: String
  var title: String
  var error: String?
  var createdAt: String
  var updatedAt: String
  var messages: [SureMessage]
  var pagination: SurePagination?

  enum CodingKeys: String, CodingKey {
    case id, title, error, messages, pagination
    case createdAt = "created_at"
    case updatedAt = "updated_at"
  }

  var chat: SureChat {
    SureChat(id: id, title: title, error: error, createdAt: createdAt, updatedAt: updatedAt)
  }
}
