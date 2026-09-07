# All Plaid data is fetched at the item-level.  This class is a simple wrapper that
# providers a convenience method, get_account_data which scopes the item-level payload
# to each Plaid Account
class PlaidItem::AccountsSnapshot
  def initialize(plaid_item, plaid_provider:)
    @plaid_item = plaid_item
    @plaid_provider = plaid_provider
  end

  def accounts
    @accounts ||= plaid_provider.get_item_accounts(plaid_item.access_token).accounts
  end

  def get_account_data(account_id)
    AccountData.new(
      account_data: accounts.find { |a| a.account_id == account_id },
      transactions_data: account_scoped_transactions_data(account_id),
      investments_data: account_scoped_investments_data(account_id),
      liabilities_data: account_scoped_liabilities_data(account_id)
    )
  end

  # The cursor Plaid returned for this fetch, which the importer stores so the
  # next sync picks up where this one stopped.
  #
  # @return [String, nil] nil when this item does not fetch transactions
  def transactions_cursor
    return nil unless transactions_data
    transactions_data.cursor
  end

  # The replay marker as it stood when the cursor was read. The importer uses it
  # to clear only the request this fetch actually served — a replay requested
  # mid-sync has a later timestamp and must survive to be honoured by the next one.
  #
  # @return [Time, nil]
  def replay_consumed_at
    transactions_data
    @replay_consumed_at
  end

  private
    attr_reader :plaid_item, :plaid_provider

    TransactionsData = Data.define(:added, :modified, :removed)
    LiabilitiesData = Data.define(:credit, :mortgage, :student)
    InvestmentsData = Data.define(:transactions, :holdings, :securities)
    AccountData = Data.define(:account_data, :transactions_data, :investments_data, :liabilities_data)

    def account_scoped_transactions_data(account_id)
      return nil unless transactions_data

      TransactionsData.new(
        added: transactions_data.added.select { |t| t.account_id == account_id },
        modified: transactions_data.modified.select { |t| t.account_id == account_id },
        removed: transactions_data.removed.select { |t| t.account_id == account_id }
      )
    end

    def account_scoped_investments_data(account_id)
      return nil unless investments_data

      transactions = investments_data.transactions.select { |t| t.account_id == account_id }
      holdings = investments_data.holdings.select { |h| h.account_id == account_id }
      securities = transactions.count > 0 && holdings.count > 0 ? investments_data.securities : []

      InvestmentsData.new(
        transactions: transactions,
        holdings: holdings,
        securities: securities
      )
    end

    def account_scoped_liabilities_data(account_id)
      return nil unless liabilities_data

      LiabilitiesData.new(
        credit: liabilities_data.credit&.find { |c| c.account_id == account_id },
        mortgage: liabilities_data.mortgage&.find { |m| m.account_id == account_id },
        student: liabilities_data.student&.find { |s| s.account_id == account_id }
      )
    end

    # @return [Boolean] whether this item is entitled to transactions and has
    #   any account to fetch them for
    def can_fetch_transactions?
      plaid_item.supports_product?("transactions") && accounts.any?
    end

    # Fetches the transaction delta, or the full history when a replay is owed.
    # Memoized: the cursor decision is made once per sync, and the timestamp it
    # acted on is captured for the importer to consume.
    #
    # @return [Object, nil] Plaid's sync response, or nil when not fetching
    def transactions_data
      return nil unless can_fetch_transactions?

      @transactions_data ||= begin
        # A pending replay means we deliberately discard the cursor and ask Plaid
        # for everything again, so a naming-preference change reaches existing
        # transactions. Captured here, at the moment of the read, so the importer
        # can tell this request apart from one raised while the sync was running.
        @replay_consumed_at = plaid_item.replay_requested_at
        cursor = @replay_consumed_at.present? ? nil : plaid_item.next_cursor

        plaid_provider.get_transactions(plaid_item.access_token, next_cursor: cursor)
      end
    end

    # @return [Boolean] whether this item is entitled to investments and holds
    #   at least one investment account
    def can_fetch_investments?
      plaid_item.supports_product?("investments") &&
      accounts.any? { |a| a.type == "investment" }
    end

    def investments_data
      return nil unless can_fetch_investments?
      @investments_data ||= plaid_provider.get_item_investments(plaid_item.access_token)
    end

    def can_fetch_liabilities?
      plaid_item.supports_product?("liabilities") &&
      accounts.any? do |a|
        a.type == "credit" && a.subtype == "credit card" ||
        a.type == "loan" && (a.subtype == "mortgage" || a.subtype == "student")
      end
    end

    def liabilities_data
      return nil unless can_fetch_liabilities?
      @liabilities_data ||= plaid_provider.get_item_liabilities(plaid_item.access_token)
    end
end
