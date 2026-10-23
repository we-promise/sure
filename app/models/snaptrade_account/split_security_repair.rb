# Repairs one account's SnapTrade positions whose holdings and trades sit on
# different Security rows of the same ticker.
#
# Before #3999, resolve_security looked a ticker up with no exchange and no
# ORDER BY, so a position's holdings and trades could land on different rows. Every cost-basis reader filters on security_id, so such a
# holding shows "No cost basis". The deterministic lookup keeps a position on
# the row it already holds, which keeps an existing split in place rather than
# healing it.
#
# The repair moves this account's rows only. It never destroys a Security,
# never moves a Security::Price (prices are shared by every family holding the
# security), and leaves other providers' holdings and other accounts alone.
# The target is the row held_security_for returns -- the one the next sync
# resolves to -- so the repaired position stays put.
#
# Only rows of one listing are merged. Security uniqueness is scoped to
# exchange_operating_mic, so the same ticker on two exchanges is two real
# instruments; a ticker whose rows name more than one exchange is skipped and
# reported in #conflicts for review by hand.
#
# A dry run (the default) reports what it would do and writes nothing. A live
# run refuses, writing nothing, when a source row has a split the target lacks,
# or when the moved history would have dates priced on a source row but not on
# the target, unless allow_price_gaps is set. A live run that fails is rolled
# back and recorded in the debug log.
class SnaptradeAccount::SplitSecurityRepair
  include SnaptradeAccount::DataHelpers

  class Refused < StandardError; end
  class PriceGapsRefused < Refused; end
  class SplitHistoryRefused < Refused; end

  # Rows reached a source security while the repair ran; it rolled back.
  class ConcurrentChange < StandardError; end

  Result = Data.define(
    :account, :ticker, :target_id, :target_source, :source_ids,
    :trades_moved, :holdings_moved, :holdings_dropped, :holdings_replaced, :dropped_snapshots,
    :price_gap_dates, :unmatched_split_dates
  )

  def self.accounts
    Account.where(id: AccountProvider.where(provider_type: "SnaptradeAccount").select(:account_id))
  end

  def initialize(account, dry_run: true, allow_price_gaps: false)
    @account = account
    @dry_run = dry_run
    @allow_price_gaps = allow_price_gaps
  end

  def dry_run?
    @dry_run
  end

  def snaptrade_linked?
    snaptrade_provider_id.present?
  end

  # { "TICKER" => [[security_id, exchange], ...] } for tickers the last run
  # skipped because their rows name more than one exchange.
  def conflicts
    @conflicts ||= {}
  end

  def run
    @conflicts = {}
    return [] unless snaptrade_provider_id

    plans = split_tickers.filter_map { |ticker, security_ids| plan_for(ticker, security_ids) }
    return [] if plans.empty?

    return plans.map { |plan| plan[:result] } if dry_run?

    refuse_unmatched_splits!(plans)
    refuse_price_gaps!(plans) unless @allow_price_gaps

    begin
      ActiveRecord::Base.transaction do
        plans.each { |plan| apply(plan) }
        refuse_concurrent_change!(plans)
        Balance::Materializer.new(
          account, strategy: :reverse, security_ids: plans.map { |plan| plan[:result].target_id }
        ).materialize_balances
      end
    rescue StandardError => e
      capture_failure(e, plans)
      raise
    end

    plans.map { |plan| plan[:result] }
  end

  private
    attr_reader :account

    def snaptrade_provider_id
      @snaptrade_provider_id ||= account.account_providers.find_by(provider_type: "SnaptradeAccount")&.id
    end

    # SnapTrade's own holdings and those with no provider (materialized from
    # the account's trades). Another provider's holding is that provider's.
    def repairable_holdings
      account.holdings.where(account_provider_id: [ snaptrade_provider_id, nil ])
    end

    # { "TICKER" => [security_id, ...] } for tickers spread over more than one
    # row of one listing. The split this repairs is a SnapTrade-created row
    # (its exchange in exchange_mic, exchange_operating_mic nil) beside a row
    # with exchange_operating_mic set, so a row's exchange is its operating
    # MIC, else its exchange_mic. A row with neither fits any group; two
    # different exchanges mean two listings, and the ticker goes to conflicts.
    def split_tickers
      security_ids = (account.trades.distinct.pluck(:security_id) + repairable_holdings.distinct.pluck(:security_id)).uniq

      groups = Security.where(id: security_ids)
        .pluck(:id, :ticker, :exchange_operating_mic, :exchange_mic)
        .group_by { |_id, ticker, _operating_mic, _mic| ticker.to_s.upcase.strip }
        .select { |ticker, rows| ticker.present? && rows.size > 1 }
        .transform_values do |rows|
          rows.map do |id, _ticker, operating_mic, mic|
            [ id, Security.canonical_exchange_operating_mic(operating_mic.presence || mic.presence) ]
          end.sort
        end

      groups.each_with_object({}) do |(ticker, rows), splits|
        if rows.filter_map(&:last).uniq.size > 1
          conflicts[ticker] = rows
        else
          splits[ticker] = rows.map(&:first)
        end
      end.sort.to_h
    end

    def plan_for(ticker, security_ids)
      target_id, target_source = target_for(ticker, security_ids)
      source_ids = security_ids - [ target_id ]
      return nil if source_ids.empty?

      trades = account.trades.where(security_id: source_ids)
      moves, drops, replaced = holding_moves(target_id, source_ids)

      {
        trades: trades,
        moves: moves,
        drops: drops + replaced,
        result: Result.new(
          account: account,
          ticker: ticker,
          target_id: target_id,
          target_source: target_source,
          source_ids: source_ids,
          trades_moved: trades.count,
          holdings_moved: moves.size,
          holdings_dropped: drops.size,
          holdings_replaced: replaced.size,
          dropped_snapshots: dropped_snapshots(drops),
          price_gap_dates: price_gap_dates(target_id, source_ids),
          unmatched_split_dates: unmatched_split_dates(target_id, source_ids)
        )
      }
    end

    # The row the next sync resolves to, or, with no holding to name one, the
    # row with the most trades. provider_row stays false, as for trades: the
    # position's trades follow the row its holdings sit on, which for a
    # same-ticker remap is the chosen row, not provider_security_id.
    def target_for(ticker, security_ids)
      held = held_security_for(account, ticker, snaptrade_provider_id)
      return [ held.id, :held ] if held

      counts = account.trades.where(security_id: security_ids).group(:security_id).count
      [ security_ids.max_by { |id| [ counts.fetch(id, 0), -security_ids.index(id) ] }, :most_trades ]
    end

    # One holding per date and currency survives, never a sum. The target
    # keeps what it already has, except that a calculated target row gives way
    # to a SnapTrade snapshot: the re-materialization rebuilds calculated rows
    # from the trades, but the snapshot is the only record of that day's
    # provider cost basis. Provider rows go first, so where two non-target rows
    # share a date the provider's snapshot is the one kept.
    #
    # Returns [moves, drops, replaced]: source holdings to move, source
    # holdings to delete, and calculated target holdings a snapshot replaces.
    def holding_moves(target_id, source_ids)
      calculated_on_target = account.holdings.where(security_id: target_id, account_provider_id: nil)
        .pluck(:date, :currency, :id).to_h { |date, currency, id| [ [ date, currency ], id ] }
      taken = account.holdings.where(security_id: target_id).pluck(:date, :currency).to_set
      moves = []
      drops = []
      replaced = []

      repairable_holdings.where(security_id: source_ids)
        .order(:date, Arel.sql("account_provider_id IS NULL"), :id)
        .each do |holding|
          key = [ holding.date, holding.currency ]
          if holding.account_provider_id == snaptrade_provider_id && calculated_on_target.key?(key)
            replaced << calculated_on_target.delete(key)
            moves << holding.id
          elsif taken.include?(key)
            drops << holding.id
          else
            taken << key
            moves << holding.id
          end
        end

      [ moves, drops, replaced ]
    end

    # [date, cost_basis] of the SnapTrade snapshots a same-day collision
    # drops, so a dry run shows which provider cost basis a live run discards.
    def dropped_snapshots(drop_ids)
      Holding.where(id: drop_ids, account_provider_id: snaptrade_provider_id).order(:date, :id).pluck(:date, :cost_basis)
    end

    # Dates in the account's history with a price on another row and none on
    # the target. Prices are not moved, so these days can go unpriced in the
    # moved history until market data fills the target.
    def price_gap_dates(target_id, source_ids)
      dates = account.start_date..Date.current
      target_dates = Security::Price.where(security_id: target_id, date: dates).distinct.pluck(:date)

      (Security::Price.where(security_id: source_ids, date: dates).distinct.pluck(:date) - target_dates).sort
    end

    # Ex-dates of the source rows' splits that the target has no split of the
    # same ratio for. The holding calculators load splits by security_id, so
    # trades moved onto the target would replay without them. A split only
    # the target has is left alone: it is the same instrument's history.
    def unmatched_split_dates(target_id, source_ids)
      on_target = Security::Split.where(security_id: target_id).pluck(:ex_date, :numerator, :denominator).to_set

      Security::Split.where(security_id: source_ids)
        .pluck(:ex_date, :numerator, :denominator)
        .reject { |split| on_target.include?(split) }
        .map(&:first).uniq.sort
    end

    # Not overridable: moving the split onto the target is a market-data
    # change for every family holding it, which this repair never makes.
    def refuse_unmatched_splits!(plans)
      unmatched = plans.map { |plan| plan[:result] }.select { |result| result.unmatched_split_dates.any? }
      return if unmatched.empty?

      summary = unmatched.map { |result| "#{result.ticker}: #{result.unmatched_split_dates.map(&:iso8601).join(', ')}" }.join("; ")
      raise SplitHistoryRefused,
        "splits on a source row but not the target (#{summary}); record them on the target first"
    end

    def capture_failure(error, plans)
      DebugLogEntry.capture(
        category: "provider_sync_error",
        level: "error",
        message: "SnapTrade split security repair failed and was rolled back: #{error.class}: #{error.message}",
        source: self.class.name,
        provider_key: "snaptrade",
        account: account,
        account_provider_id: snaptrade_provider_id,
        metadata: {
          error_class: error.class.name,
          tickers: plans.map { |plan| plan[:result].ticker },
          backtrace: error.backtrace&.first(5)
        }
      )
    end

    # The plans are built before the transaction opens, and a sync can add a
    # holding or trade to a source row in between (or after apply read the
    # trades). Moving the rest and leaving that row behind would re-split the
    # position, so roll back and let the task be run again. A holding another
    # provider owns stays on its row by design and is not counted.
    def refuse_concurrent_change!(plans)
      changed = plans.map { |plan| plan[:result] }.select do |result|
        repairable_holdings.where(security_id: result.source_ids).exists? ||
          account.trades.where(security_id: result.source_ids).exists?
      end
      return if changed.empty?

      raise ConcurrentChange,
        "rows reached a source security during the repair (#{changed.map(&:ticker).join(', ')}); run it again"
    end

    def refuse_price_gaps!(plans)
      gapped = plans.map { |plan| plan[:result] }.select { |result| result.price_gap_dates.any? }
      return if gapped.empty?

      summary = gapped.map { |result| "#{result.ticker}: #{result.price_gap_dates.size} date(s)" }.join(", ")
      raise PriceGapsRefused,
        "price gaps on the target row (#{summary}); backfill its prices or allow price gaps for this account"
    end

    def apply(plan)
      target_id = plan[:result].target_id

      now = Time.current
      Holding.where(id: plan[:drops]).delete_all if plan[:drops].any?
      Holding.where(id: plan[:moves]).update_all(security_id: target_id, updated_at: now) if plan[:moves].any?

      # Report caches key on the latest entry updated_at
      # (Family#entries_cache_version), and update_all bypasses that, so the
      # moved trades' entries are stamped too.
      trade_ids = plan[:trades].pluck(:id)
      return if trade_ids.empty?

      Trade.where(id: trade_ids).update_all(security_id: target_id, updated_at: now)
      Entry.where(entryable_type: "Trade", entryable_id: trade_ids).update_all(updated_at: now)
    end
end
