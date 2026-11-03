# Shows an eToro account by eToro's own totals (EtoroAccount#shown_as_totals?).
# On every day its balance history covers, and today, the account's total is
# eToro's total and its cash eToro's cash; the rest, whatever eToro holds
# directly or through copy-trading, is one holding worth the difference. No
# trades or holdings of eToro's positions are kept, as the trade history
# eToro reports cannot account for every past day's holdings.
#
# Sure works out a day's cash as the total less the holdings (Balance::*), so
# the holding is reported for each of those days: provider holdings of past
# days stand as eToro's (Holding::Materializer). A day eToro sent no figures
# for carries the holding of the day before it, as the holdings history does
# for any day without a price, and the cash of the day after it, as the
# balance history does between two reconciliations.
class EtoroAccount::TotalsProcessor
  include EtoroAccount::DataHelpers

  TICKER_PREFIX = "ETORO-INVESTMENTS-".freeze

  class << self
    # The security standing for the account's investments, one per Sure
    # account. It is of kind "cash", as Security.cash_for's are, though it is
    # not cash: Sure counts every holding, of either kind, as invested, while
    # a cash security is never health checked, priced by the market data
    # import, given a Brandfetch logo or offered for a trade, so it spends no
    # price provider's requests. Its ticker names the account, so no other
    # account resolves to it.
    def security_for(account)
      Security.find_or_create_by!(ticker: ticker_for(account), kind: "cash") do |security|
        security.name = I18n.t("etoro_items.totals.security_name")
        security.offline = true
      end
    end

    # Starts the account the day before its oldest entry, whether that is
    # earlier or later than its anchor. Only the zero anchor a linked account
    # starts with is moved, as Account#ensure_opening_anchor_precedes_entries
    # does, and through the manager directly as there, so it queues no sync
    # of its own; the caller's sync follows anyway.
    def fit_opening_anchor!(account)
      return unless account.has_opening_anchor? && account.opening_anchor_balance.zero?

      anchor_entry_id = account.valuations.opening_anchor.first&.entry&.id
      oldest = account.entries.where.not(id: anchor_entry_id).minimum(:date)
      return if oldest.nil? || account.opening_anchor_date == oldest.prev_day

      result = Account::OpeningBalanceManager.new(account).set_opening_balance(balance: 0, date: oldest.prev_day)
      raise Provider::Etoro::Error, "Failed to move the opening balance: #{result.error}" unless result.success?
    end

    # Takes the totals off an account shown as holdings again. The holdings
    # history works out the days before today again from the trades.
    def clear(account)
      security = Security.find_by(ticker: ticker_for(account), kind: "cash")
      account.holdings.where(security_id: security.id).delete_all if security
    end

    private

      def ticker_for(account)
        "#{TICKER_PREFIX}#{account.id}".upcase
      end
  end

  def initialize(etoro_account)
    @etoro_account = etoro_account
  end

  # Returns today's value of the investments.
  def process
    return BigDecimal("0") unless account.present?

    remove_position_records!
    values = daily_values
    write_holdings(values)
    values.fetch(Date.current)
  end

  # Starts the account the day before the first of eToro's daily balances,
  # where its history begins once the trades, which may reach further back,
  # are gone.
  def fit_opening_anchor!
    self.class.fit_opening_anchor!(account)
  end

  private

    def account
      @etoro_account.current_account
    end

    def provider_id
      @etoro_account.account_provider&.id
    end

    def currency
      @etoro_account.currency
    end

    def security
      @security ||= self.class.security_for(account)
    end

    # The trades of eToro's positions and the holdings worked out from them
    # or reported for them. A trade the user added stays, with the holdings
    # the next sync works out from it; those count beside the investments, so
    # on the days they cover the cash differs from eToro's by their value.
    # The securities they leave go when nothing else uses them (see
    # DataHelpers#discard_unused_securities).
    def remove_position_records!
      trades = account.entries.where(source: "etoro", entryable_type: "Trade")
      left = Trade.where(id: trades.select(:entryable_id)).distinct.pluck(:security_id) |
        account.holdings.where.not(security_id: security.id).distinct.pluck(:security_id)
      trades.destroy_all
      account.holdings.where.not(security_id: security.id).delete_all
      discard_unused_securities(left)
    end

    # The investments' value by day: eToro's total less its cash on each past
    # day it reported both, and today's from the current figures. A value
    # below zero, should eToro report more cash than its total, is held at
    # zero, as a holding cannot be worth less.
    def daily_values
      values = Array(@etoro_account.raw_balance_history_payload).each_with_object({}) do |snapshot, by_date|
        next if snapshot["currency"].present? && snapshot["currency"] != currency

        date = parse_date(snapshot["date"])
        total = parse_decimal(snapshot["total"])
        cash = parse_decimal(snapshot["cash"])
        by_date[date] = invested(total, cash) if date && date < Date.current && total && cash
      end

      values.merge(Date.current => invested(@etoro_account.current_balance || 0, @etoro_account.cash_balance || 0))
    end

    def invested(total, cash)
      [ total - cash, BigDecimal("0") ].max.round(4)
    end

    # Holding::CurrentForInvestmentAccounts counts every provider holding
    # written on the account's latest import day as current, whatever day it
    # is for. So a past day's row is stamped with the end of that day, as if
    # written then, and only today's with the time of this sync.
    def write_holdings(values)
      now = Time.current
      rows = values.map do |date, value|
        written_at = date < Date.current ? date.in_time_zone("UTC").end_of_day : now
        {
          account_id: account.id,
          security_id: security.id,
          date: date,
          currency: currency,
          qty: 1,
          price: value,
          amount: value,
          account_provider_id: provider_id,
          external_id: "etoro_totals_#{@etoro_account.etoro_account_id}_#{date.iso8601}",
          created_at: written_at,
          updated_at: written_at
        }
      end

      rows.each_slice(500) { |batch| Holding.upsert_all(batch, unique_by: %i[account_id security_id date currency], record_timestamps: false) }
    end
end
