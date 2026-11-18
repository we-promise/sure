# Turns the Sure account of a moomoo cash row that was set up as an
# investment account into a cash (Depository) account, the type a cash row's
# account is created as now (see MoomooAccount#sure_accountable), so its money
# counts as cash in net worth.
#
# Sure has no way for a user to change an account's type, but an account
# delegates its type to its accountable record, and an Investment and a
# Depository record hold the same fields (a subtype and its locks). So the
# account keeps its id and everything that hangs off it, its entries,
# transfers, balances, provider link, shares and goals, and only its
# accountable is replaced. A cash account holds no holdings, so its daily
# balances work back from its entries as before.
#
# Runs on every sync and does nothing once the account is a cash account.
# Left alone:
# - an investment account the user made and linked to the cash row
#   themselves, rather than one the setup created for it;
# - an account that still holds trades or holdings, which a former combined
#   account keeps until its currency's stocks account takes them (see
#   MoomooAccount::CurrencyRouter); the sync that moves them converts it. A
#   trade the user edited moves only once its currency's stocks account is
#   set up; until then its account stays an investment account, and each sync
#   logs that it waits on it.
class MoomooAccount::CashAccountConversion
  CONTRIBUTION_LABELS = MoomooAccount::CashLogsProcessor::CASH_ACCOUNT_UNLABELED
  CASH_LOG_EXTERNAL_ID_PATTERN = MoomooAccount::CurrencyRouter::CASH_LOG_EXTERNAL_ID_PATTERN

  def initialize(moomoo_account)
    @moomoo_account = moomoo_account
  end

  # Returns whether it converted the account.
  def convert
    unless convertible?
      log_waiting if waiting_on_investments?
      return false
    end

    changes = account.with_lock do
      next unless convertible?

      investment = account.accountable
      account.update!(accountable: MoomooAccount::CASH_ACCOUNTABLE[:type].constantize.new(subtype: MoomooAccount::CASH_ACCOUNTABLE[:subtype]))
      investment.destroy!
      { transfers: align_transfers, labels: reset_contribution_labels }
    end
    return false unless changes

    log(**changes)
    true
  rescue => e
    DebugLogEntry.capture(
      category: "sync",
      level: "error",
      message: "MoomooAccount::CashAccountConversion - Failed to make the cash account a Depository: #{e.class} - #{e.message}",
      source: "moomoo",
      provider_key: "moomoo",
      family: moomoo_account.moomoo_item.family,
      account_provider: moomoo_account.account_provider,
      metadata: { moomoo_account_id: moomoo_account.id }
    )
    false
  end

  private

    attr_reader :moomoo_account

    def account
      @account ||= moomoo_account.current_account
    end

    def convertible?
      candidate? && !holds_investments?
    end

    def candidate?
      moomoo_account.cash_role? && account&.investment? && !account.pending_deletion? && !account.disabled? && created_by_setup?
    end

    def holds_investments?
      account.entries.where(entryable_type: "Trade").exists? || account.holdings.exists?
    end

    def waiting_on_investments?
      candidate? && holds_investments?
    end

    def created_by_setup?
      moomoo_account.setup_account_id.present? && moomoo_account.setup_account_id == account.id
    end

    # Each transfer of the account takes the kinds Sure gives a transfer to or
    # from a cash account: a trade's payment and a currency exchange stay
    # funds movements (see MoomooAccount::TradeSettlements.keep_funds_movement!
    # and MoomooAccount::CashLogsProcessor.exchange?), and any other
    # transfer is realigned as Transfer::InvestmentKindReconciler would,
    # except for a kind the user locked.
    def align_transfers
      ids = account.transactions.select(:id)
      transfers = Transfer.confirmed.where(inflow_transaction_id: ids).or(Transfer.confirmed.where(outflow_transaction_id: ids))
      changed = 0

      transfers.includes(inflow_transaction: { entry: :account }, outflow_transaction: [ :category, { entry: :account } ]).find_each do |transfer|
        if settlement?(transfer) || MoomooAccount::CashLogsProcessor.exchange?(transfer)
          MoomooAccount::TradeSettlements.keep_funds_movement!(transfer)
          next
        end

        [ transfer.inflow_transaction, transfer.outflow_transaction ].each do |transaction|
          next unless Transaction::TRANSFER_KINDS.include?(transaction.kind) && !transaction.locked?(:kind) && !transaction.entry.excluded?

          expected = transfer.kind_for_leg(transaction)
          next if transaction.kind == expected

          attrs = { kind: expected }
          attrs[:category] = nil if transaction.kind == "investment_contribution" && contribution_category?(transaction.category)
          transaction.update!(attrs)
          changed += 1
        end
      end

      changed
    end

    def settlement?(transfer)
      prefix = MoomooAccount::TradeSettlements::EXTERNAL_ID_PREFIX
      [ transfer.inflow_transaction, transfer.outflow_transaction ].all? { |transaction| transaction.entry.source == "moomoo" && transaction.entry.external_id.to_s.start_with?(prefix) }
    end

    # Deposits and withdrawals imported while the account was an investment
    # account carry the Contribution or Withdrawal label, and deposits the
    # investment contribution kind and category the import adapter gave
    # them. They become the plain funds movements a cash account imports.
    # Each of the three is kept where the user set it or a Rule set the
    # category; a row whose label the user chose is theirs entirely.
    def reset_contribution_labels
      entries = account.entries.where(source: "moomoo", entryable_type: "Transaction")
        .where("entries.external_id LIKE ?", CASH_LOG_EXTERNAL_ID_PATTERN)
        .joins("INNER JOIN transactions ON transactions.id = entries.entryable_id")
        .where(transactions: { investment_activity_label: CONTRIBUTION_LABELS })
      reset = 0

      entries.includes(entryable: :category).find_each do |entry|
        transaction = entry.entryable
        next if entry.excluded? || entry.import_locked? || transaction.locked?(:investment_activity_label)

        attrs = { investment_activity_label: nil }
        attrs[:kind] = transaction.transfer&.confirmed? ? transaction.transfer.kind_for_leg(transaction) : "funds_movement" unless transaction.locked?(:kind)
        if contribution_category?(transaction.category) && !transaction.locked?(:category_id) && !rule_assigned?(transaction, :category_id)
          attrs[:category] = nil
        end
        transaction.update!(attrs)
        reset += 1
      end

      reset
    end

    def contribution_category?(category)
      category.present? && Category.all_investment_contributions_names.include?(category.name)
    end

    def rule_assigned?(transaction, attribute)
      transaction.data_enrichments.exists?(attribute_name: attribute.to_s, source: "rule")
    end

    def log_waiting
      DebugLogEntry.capture(
        category: "sync",
        level: "info",
        message: "MoomooAccount::CashAccountConversion - the #{moomoo_account.currency} cash account stays an investment account while it holds trades or holdings",
        source: "moomoo",
        provider_key: "moomoo",
        family: moomoo_account.moomoo_item.family,
        account_provider: moomoo_account.account_provider,
        metadata: {
          moomoo_account_id: moomoo_account.id, account_id: account.id,
          trades: account.entries.where(entryable_type: "Trade").count, holdings: account.holdings.count
        }
      )
    end

    def log(**changes)
      DebugLogEntry.capture(
        category: "sync",
        level: "info",
        message: "MoomooAccount::CashAccountConversion - made the #{moomoo_account.currency} cash account a Depository account",
        source: "moomoo",
        provider_key: "moomoo",
        family: moomoo_account.moomoo_item.family,
        account_provider: moomoo_account.account_provider,
        metadata: { moomoo_account_id: moomoo_account.id, account_id: account.id, **changes }
      )
    end
end
