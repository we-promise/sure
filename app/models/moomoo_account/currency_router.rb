# Keeps the moomoo trades, holdings and cash log transactions of a trading
# account split by currency in the Sure account of the row that takes them
# (see MoomooAccount#trades_row_for and #cash_log_row_for). Before a split
# one Sure account was given every currency's, and a cash account set up
# later takes its currency's cash log from the account that had it; each
# account works its history back from its own, so nothing may stay counted
# in two (see also MoomooAccount::ReconciliationRestatement).
class MoomooAccount::CurrencyRouter
  CASH_LOG_EXTERNAL_ID_PATTERN = "moomoo_cash_log_%".freeze

  def initialize(moomoo_account)
    @moomoo_account = moomoo_account
  end

  # Takes this row's entries and holdings from the trading account's other
  # Sure accounts, and drops the ones whose row isn't linked: they are
  # imported there once it is. A trade or transaction the user edited stays
  # until its row's account can take it.
  def route!
    return unless account

    moomoo_account.sibling_currency_accounts.each do |sibling|
      other = sibling.current_account
      take_from(other) if other && other.id != account.id
    end
    drop_unlinked
  end

  private

    attr_reader :moomoo_account

    def account
      @account ||= moomoo_account.current_account
    end

    def currency
      moomoo_account.currency
    end

    def takes_trades?
      !moomoo_account.cash_role?
    end

    def take_from(other)
      moved_security_ids = Set.new
      moved = 0

      owned_entries(other).includes(:entryable).find_each do |entry|
        moved_security_ids << entry.entryable.security_id if entry.entryable.is_a?(Trade)
        take_entry(entry)
        moved += 1
      end

      if takes_trades?
        other.holdings.where(currency: currency).where.not(account_provider_id: nil).find_each do |holding|
          moved_security_ids << holding.security_id
          take_holding(holding)
          moved += 1
        end
      end

      drop_calculated_holdings(other, moved_security_ids)
      log_moved(other, moved) if moved.positive?
    end

    # The entries of this row's currency in `target` that this row takes.
    def owned_entries(target)
      entries = target.entries.where(source: "moomoo", currency: currency)
      scopes = []
      scopes << entries.where(entryable_type: "Trade") if takes_trades?
      scopes << cash_log_entries(entries) if moomoo_account.takes_cash_logs?
      scopes.reduce(:or) || entries.none
    end

    def cash_log_entries(entries)
      entries.where(entryable_type: "Transaction").where("entries.external_id LIKE ?", CASH_LOG_EXTERNAL_ID_PATTERN)
    end

    # An entry this account already imported again replaces the one left
    # behind, unless only the one left behind has the user's changes.
    def take_entry(entry)
      existing = account.entries.find_by(source: "moomoo", external_id: entry.external_id)
      if existing.nil?
        entry.update!(account: account)
      elsif entry.protected_from_sync? && !existing.protected_from_sync?
        existing.destroy!
        entry.update!(account: account)
      else
        entry.destroy!
      end
    end

    def take_holding(holding)
      taken = account.holdings.where(security_id: holding.security_id, date: holding.date, currency: holding.currency)
        .or(account.holdings.where(external_id: holding.external_id))
        .exists?
      taken ? holding.destroy! : holding.update!(account: account, account_provider_id: moomoo_account.account_provider&.id)
    end

    # Entries and holdings whose row is another one, not linked. Those of a
    # linked row are left for it to take.
    def drop_unlinked
      entries = account.entries.where(source: "moomoo")
      dropped_security_ids = Set.new

      dropped_currencies(entries.where(entryable_type: "Trade")) { |row_currency| moomoo_account.trades_row_for(row_currency) }.each do |row_currency|
        entries.where(entryable_type: "Trade", currency: row_currency).includes(:entryable).find_each do |entry|
          next if entry.protected_from_sync?

          dropped_security_ids << entry.entryable.security_id
          entry.destroy!
        end
      end

      cash_logs = cash_log_entries(entries)
      dropped_currencies(cash_logs) { |row_currency| moomoo_account.cash_log_row_for(row_currency) }.each do |row_currency|
        cash_logs.where(currency: row_currency).find_each { |entry| entry.destroy! unless entry.protected_from_sync? }
      end

      holdings = account.holdings.where.not(account_provider_id: nil)
      dropped_currencies(holdings) { |row_currency| moomoo_account.trades_row_for(row_currency) }.each do |row_currency|
        holdings.where(currency: row_currency).find_each do |holding|
          dropped_security_ids << holding.security_id
          holding.destroy!
        end
      end

      drop_calculated_holdings(account, dropped_security_ids)
    end

    # The currencies in `scope` whose row, as the block finds it, is neither
    # this one nor linked.
    def dropped_currencies(scope)
      scope.distinct.pluck(:currency).reject do |row_currency|
        row = yield(row_currency)
        row && (row.id == moomoo_account.id || row.current_account.present?)
      end
    end

    # Rows the holdings calculation left for the securities that moved; the
    # account they moved from no longer works them out.
    def drop_calculated_holdings(target, security_ids)
      target.holdings.where(account_provider_id: nil, security_id: security_ids.to_a).delete_all if security_ids.any?
    end

    def log_moved(other, count)
      DebugLogEntry.capture(
        category: "sync",
        level: "info",
        message: "MoomooAccount::CurrencyRouter - moved #{currency} #{moomoo_account.role} records into this row's account",
        source: "moomoo",
        provider_key: "moomoo",
        family: moomoo_account.moomoo_item.family,
        account_provider: moomoo_account.account_provider,
        metadata: { moomoo_account_id: moomoo_account.id, from_account_id: other.id, records: count }
      )
    end
end
