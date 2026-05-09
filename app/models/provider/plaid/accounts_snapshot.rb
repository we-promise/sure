# Wraps the item-level data fetched from Plaid (accounts, transactions cursor,
# investments, liabilities) and provides per-account scoping. Direct port of
# PlaidItem::AccountsSnapshot, refactored to operate on Provider::Connection
# rather than PlaidItem.
class Provider::Plaid::AccountsSnapshot
  def initialize(connection, plaid_provider:)
    @connection = connection
    @plaid_provider = plaid_provider
  end

  def accounts
    @accounts ||= plaid_provider.get_item_accounts(access_token).accounts
  end

  def get_account_data(account_id)
    AccountData.new(
      account_data:      accounts.find { |a| a.account_id == account_id },
      transactions_data: account_scoped_transactions_data(account_id),
      investments_data:  account_scoped_investments_data(account_id),
      liabilities_data:  account_scoped_liabilities_data(account_id)
    )
  end

  def transactions_cursor
    return nil unless transactions_data
    transactions_data.cursor
  end

  private
    attr_reader :connection, :plaid_provider

    TransactionsData = Data.define(:added, :modified, :removed)
    LiabilitiesData = Data.define(:credit, :mortgage, :student)
    InvestmentsData = Data.define(:transactions, :holdings, :securities)
    AccountData = Data.define(:account_data, :transactions_data, :investments_data, :liabilities_data)

    def access_token
      connection.credentials["access_token"]
    end

    def billed_products
      connection.metadata["billed_products"] || []
    end

    def supports_product?(product)
      billed_products.include?(product)
    end

    def account_scoped_transactions_data(account_id)
      return nil unless transactions_data

      TransactionsData.new(
        added:    transactions_data.added.select    { |t| t.account_id == account_id },
        modified: transactions_data.modified.select { |t| t.account_id == account_id },
        removed:  transactions_data.removed.select  { |t| t.account_id == account_id }
      )
    end

    def account_scoped_investments_data(account_id)
      return nil unless investments_data

      transactions = investments_data.transactions.select { |t| t.account_id == account_id }
      holdings     = investments_data.holdings.select     { |h| h.account_id == account_id }
      securities   = transactions.count > 0 && holdings.count > 0 ? investments_data.securities : []

      InvestmentsData.new(transactions: transactions, holdings: holdings, securities: securities)
    end

    def account_scoped_liabilities_data(account_id)
      return nil unless liabilities_data

      LiabilitiesData.new(
        credit:   liabilities_data.credit&.find   { |c| c.account_id == account_id },
        mortgage: liabilities_data.mortgage&.find { |m| m.account_id == account_id },
        student:  liabilities_data.student&.find  { |s| s.account_id == account_id }
      )
    end

    def can_fetch_transactions?
      supports_product?("transactions") && accounts.any?
    end

    def transactions_data
      return nil unless can_fetch_transactions?
      @transactions_data ||= plaid_provider.get_transactions(
        access_token,
        next_cursor: connection.metadata["next_cursor"]
      )
    end

    def can_fetch_investments?
      supports_product?("investments") && accounts.any? { |a| a.type == "investment" }
    end

    def investments_data
      return nil unless can_fetch_investments?
      @investments_data ||= plaid_provider.get_item_investments(access_token)
    end

    def can_fetch_liabilities?
      supports_product?("liabilities") && accounts.any? do |a|
        a.type == "credit" && a.subtype == "credit card" ||
        a.type == "loan" && (a.subtype == "mortgage" || a.subtype == "student")
      end
    end

    def liabilities_data
      return nil unless can_fetch_liabilities?
      @liabilities_data ||= plaid_provider.get_item_liabilities(access_token)
    end
end
