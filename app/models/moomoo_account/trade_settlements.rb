# Pays each trade of a trading account split by currency from its currency's
# cash account. The stocks account holds no cash: each fill books its gross
# amount out of (a buy) or into (a sell) the cash account, an opposite leg in
# the stocks account nets the trade's cash there to zero, and the two legs are
# linked as a transfer. moomoo reports fees per order only, so trades carry
# none and the cash log's fee rows reach the cash account on their own.
#
# The cash leg is dated by the broker's clock, as the cash log is, so a trade
# made after midnight there isn't paid for before the exchange or deposit that
# funded it; the stocks leg takes the trade's date, keeping that account's cash
# at zero every day.
#
# Each row books only the leg in its own Sure account, whether or not the
# other row's account is set up, as that cash did move: the stocks account
# never keeps its currency's cash (see MoomooAccount#cash_log_row_for). The
# stocks leg waits for its trade, which would otherwise leave cash behind.
class MoomooAccount::TradeSettlements
  include MoomooAccount::DataHelpers

  EXTERNAL_ID_PREFIX = "moomoo_settlement_".freeze
  LEG_SUFFIXES = { cash: "_cash", stocks: "_stocks" }.freeze

  # A buy pays from a cash account, a Depository, into a stocks account, an
  # Investment, which Sure counts as an investment contribution, a budgeted
  # expense. The cash only changes hands inside the brokerage account, so the
  # payment is made a plain funds movement the way a user would switch it
  # (Transfer#update_investment_contribution!): the locked kind is kept by
  # later syncs and by Transfer::InvestmentKindReconciler. A choice the user
  # made already, either way, is left alone.
  def self.keep_funds_movement!(transfer)
    return unless transfer.investment_contribution_switchable?
    return if transfer.outflow_transaction.locked?(:kind)

    transfer.update_investment_contribution!(false)
  end

  def initialize(moomoo_account)
    @moomoo_account = moomoo_account
  end

  def process
    return unless account.present? && moomoo_account.split_by_currency?

    if moomoo_account.cash_role?
      book_legs(:cash)
    elsif moomoo_account.stocks_role?
      moomoo_account.cash_row_for(moomoo_account.currency) ? book_legs(:stocks) : drop_stocks_legs
    end
  end

  private

    attr_reader :moomoo_account

    def account
      @account ||= moomoo_account.current_account
    end

    def import_adapter
      @import_adapter ||= Account::ProviderImportAdapter.new(account)
    end

    def orders
      @orders ||= moomoo_account.source_account.orders_map
    end

    def positions_by_code
      @positions_by_code ||= moomoo_account.positions_by_code
    end

    def book_legs(leg)
      moomoo_account.currency_fills.each do |fill|
        if fill["status"].to_s == "CANCELLED"
          remove_leg(fill, leg)
          next
        end

        details = trade_fill_details(fill, orders, positions_by_code)
        next if details.is_a?(Symbol)

        if leg == :stocks && !traded?(fill)
          remove_leg(fill, leg)
          next
        end

        transaction = import_leg(fill, leg, details)
        link(fill, leg, transaction) if transaction
      rescue => e
        capture_failure(fill, e)
      end
    end

    # A buy pays out of the cash account and into the stocks account; a sell
    # the other way round.
    def import_leg(fill, leg, details)
      out_of_cash = details[:buy] == (leg == :cash)
      entry = import_adapter.import_transaction(
        external_id: leg_external_id(fill, leg),
        amount: out_of_cash ? details[:gross] : -details[:gross],
        currency: details[:currency],
        date: leg == :cash ? broker_date(fill) || details[:date] : details[:date],
        name: I18n.t("moomoo_items.settlements.#{details[:buy] ? 'buy' : 'sell'}", symbol: details[:info][:ticker]),
        source: "moomoo",
        kind: "funds_movement",
        investment_activity_label: "Transfer",
        allow_heuristic_matching: false
      )
      entry&.entryable if entry&.entryable.is_a?(Transaction)
    end

    def broker_date(fill)
      trade_date(fill["create_time"], MoomooAccount::CashLogsProcessor::FIRM_TIME_ZONES.fetch(moomoo_account.security_firm.to_s, "UTC"))
    end

    def traded?(fill)
      account.entries.exists?(source: "moomoo", external_id: fill_external_id(fill), entryable_type: "Trade")
    end

    # A leg the user edited or excluded is left alone.
    def remove_leg(fill, leg)
      entry = account.entries.find_by(source: "moomoo", external_id: leg_external_id(fill, leg), entryable_type: "Transaction")
      entry.destroy! if entry && !entry.protected_from_sync?
    end

    # The currency has no cash row: the account isn't split by it any more.
    def drop_stocks_legs
      pattern = "#{Entry.sanitize_sql_like(EXTERNAL_ID_PREFIX)}%#{Entry.sanitize_sql_like(LEG_SUFFIXES[:stocks])}"
      account.entries.where(source: "moomoo", entryable_type: "Transaction").where("entries.external_id LIKE ?", pattern).find_each do |entry|
        entry.destroy! unless entry.protected_from_sync?
      end
    end

    # Once both legs are in, they are a transfer from the account the money
    # left, unless the user unlinked them. It stays a plain funds movement
    # (see .keep_funds_movement!).
    def link(fill, leg, transaction)
      other_leg = leg == :cash ? :stocks : :cash
      other_row = leg == :cash ? moomoo_account.trades_row_for(moomoo_account.currency) : moomoo_account.cash_row_for(moomoo_account.currency)
      other_account = other_row&.current_account
      return unless other_row && other_row.role == other_leg.to_s && other_account

      other = other_account.entries.find_by(source: "moomoo", external_id: leg_external_id(fill, other_leg), entryable_type: "Transaction")&.entryable
      return unless other

      inflow, outflow = transaction.entry.amount.negative? ? [ transaction, other ] : [ other, transaction ]
      existing = inflow.transfer || outflow.transfer
      if existing
        self.class.keep_funds_movement!(existing) if existing.inflow_transaction_id == inflow.id && existing.outflow_transaction_id == outflow.id
        return
      end
      return if RejectedTransfer.exists?(inflow_transaction_id: inflow.id, outflow_transaction_id: outflow.id)

      self.class.keep_funds_movement!(Transfer.create!(inflow_transaction: inflow, outflow_transaction: outflow, status: "confirmed"))
    end

    def leg_external_id(fill, leg)
      "#{EXTERNAL_ID_PREFIX}#{moomoo_account.moomoo_account_id}_#{fill['deal_id']}#{LEG_SUFFIXES.fetch(leg)}"
    end

    def capture_failure(fill, error)
      DebugLogEntry.capture(
        category: "sync",
        level: "error",
        message: "MoomooAccount::TradeSettlements - Failed to book the cash of fill #{fill['deal_id']}: #{error.message}",
        source: "moomoo",
        provider_key: "moomoo",
        family: moomoo_account.moomoo_item.family,
        account_provider: moomoo_account.account_provider,
        metadata: { deal_id: fill["deal_id"], moomoo_account_id: moomoo_account.id, role: moomoo_account.role }
      )
    end
end
