class EtoroItem::Importer
  include CurrencyNormalizable
  include EtoroAccount::DataHelpers

  TRADING_ACCOUNT_TYPE = "Trading".freeze

  # eToro reports a position's amount and cost in USD and its P&L in the
  # account currency, so the two add up only in a USD account.
  SUPPORTED_CURRENCY = "USD".freeze
  USD_CURRENCY_ID = 1

  # eToro serves daily balances for the last year less a day, and the trade
  # history walk keeps only the trades closed within that window. Trades
  # stored by earlier syncs stay, and a buy is dated on the day its position
  # opened, so the holdings history still reaches back before the window,
  # where no daily balance pins it.
  HISTORY_WINDOW_DAYS = 364

  # Recent days are fetched again on every sync, in case eToro amended them.
  BALANCE_HISTORY_OVERLAP_DAYS = 3

  # A safety stop for the trade history walk, far above any real account.
  MAX_TRADE_HISTORY_PAGES = 200

  TradeHistory = Data.define(:trades, :complete)

  attr_reader :etoro_item, :provider

  def initialize(etoro_item, provider:)
    @etoro_item = etoro_item
    @provider = provider
    @partial_failures = []
    @rate_limited_at = nil
  end

  # Imports the primary trading account. The PnL endpoint describes the real
  # account as a whole, so its positions belong to that one account.
  # Positions and the balance must arrive; the histories, instrument metadata
  # and prices are kept from the last sync when eToro fails to send them, and
  # those failures are returned for the sync to report. An account not held
  # in USD is refused before anything is stored.
  def import
    # Before asking eToro anything, so that a key eToro now refuses does not
    # keep its prices on securities no account values with them.
    etoro_item.release_unused_prices!

    balance = primary_trading_balance
    raise Provider::Etoro::ApiError, "eToro returned no trading account" unless balance

    currency = account_currency(balance)
    ensure_supported_currency!(currency)
    current_balance = parse_decimal(field(balance, "balance"))
    raise Provider::Etoro::ApiError.new("eToro returned a trading account without a balance", status_code: 200) if current_balance.nil?

    account_id = field(balance, "accountId").to_s.presence || "real"
    etoro_account = etoro_item.etoro_accounts.find_or_initialize_by(etoro_account_id: account_id)
    today = Date.current
    window_start = today - HISTORY_WINDOW_DAYS

    portfolio = provider.fetch_portfolio
    ensure_supported_currency!(currency, field(field(portfolio, "clientPortfolio") || portfolio, "accountCurrencyId"))
    positions = open_positions(portfolio)
    history = fetch_trades(etoro_account, window_start)
    snapshots = fetch_balance_snapshots(etoro_account, account_id, today, window_start)

    ActiveRecord::Base.transaction do
      etoro_account.assign_attributes(
        name: I18n.t("etoro_items.defaults.name"),
        account_type: "trading",
        currency: currency,
        current_balance: current_balance,
        cash_balance: available_cash(balance, portfolio),
        raw_positions_payload: positions,
        position_settlement_types: (etoro_account.position_settlement_types || {}).merge(settlement_types_of(positions)),
        last_positions_sync: Time.current
      )

      if history
        etoro_account.raw_trades_payload = merge_trades(etoro_account.raw_trades_payload, history.trades)
        # An unfinished walk leaves no watermark: the trades it stored would
        # otherwise end the next walk before the ones it missed.
        etoro_account.trades_synced_through = history.complete ? today : nil
      end

      unless snapshots.nil?
        etoro_account.raw_balance_history_payload = merge_snapshots(etoro_account.raw_balance_history_payload, snapshots)
      end

      etoro_account.save!
      record_snapshots!(etoro_account, balance, portfolio, today)
      etoro_item.update!(status: :good)
    end

    sync_copy_accounts!(etoro_account)

    # An account shown by its totals values no instrument, but keeps the
    # positions and trades eToro sends for a return to holdings.
    refresh_instruments!(etoro_account) unless etoro_account.shown_as_totals?
    import_price_history!(etoro_account)

    { success: true, partial_failures: @partial_failures, rate_limited_at: @rate_limited_at }
  end

  private

    # The currency eToro names for the account, USD when it names none.
    def account_currency(balance)
      reported = field(balance, "currency")
      parse_currency(reported) || reported.presence&.to_s || SUPPORTED_CURRENCY
    end

    # Refuses an account not held in USD rather than book its USD position
    # figures in another currency. eToro's own example omits
    # accountCurrencyId, so only an ID it does send is checked.
    def ensure_supported_currency!(currency, currency_id = nil)
      return if currency == SUPPORTED_CURRENCY && (currency_id.blank? || currency_id.to_i == USD_CURRENCY_ID)

      raise Provider::Etoro::UnsupportedAccountError,
        "eToro account currency #{currency_id.blank? ? currency : "ID #{currency_id}"} is not supported yet; Sure imports USD eToro accounts only"
    end

    # The Trading entry already linked when there is one, so a second Trading
    # entry eToro starts listing cannot take its place.
    def primary_trading_balance
      data = provider.fetch_balances(account_types: TRADING_ACCOUNT_TYPE)
      trading = Array(field(data, "balances")).select { |balance| field(balance, "accountType").to_s.casecmp?(TRADING_ACCOUNT_TYPE) }
      stored_ids = etoro_item.etoro_accounts.filter_map(&:etoro_account_id)

      trading.find { |balance| stored_ids.include?(field(balance, "accountId").to_s) } ||
        trading.find { |balance| !field(balance, "subType").to_s.casecmp?("subAccount") }
    end

    # Direct positions and those held through copy-trading mirrors. A
    # response without a positions list is not an empty portfolio: stored as
    # one, it would close every holding.
    def open_positions(data)
      portfolio = field(data, "clientPortfolio") || data
      direct = field(portfolio, "positions")
      raise Provider::Etoro::ApiError.new("eToro returned a portfolio without positions", status_code: 200) unless direct.is_a?(Array)

      mirrored = Array(field(portfolio, "mirrors")).flat_map { |mirror| Array(field(mirror, "positions")) }

      (direct + mirrored).uniq { |position| field(position, "positionID").to_s }
    end

    # Walks the trade history from the newest close back and keeps the trades
    # closed within the window. Only an empty page ends the history, since a
    # short one can have more after it. As later pages are older, a page with
    # no trade not yet known ends the walk too: the stored trades are known
    # once a walk has finished, and so are those this walk has read. A page
    # holding only trades this walk has read is eToro answering an earlier
    # page again rather than the end, so the walk stops there unfinished,
    # which leaves no watermark. Returns nil, leaving the stored trades as
    # they are, when eToro fails partway.
    def fetch_trades(etoro_account, window_start)
      stored = etoro_account.trades_synced_through ? trade_keys(etoro_account.raw_trades_payload) : Set.new
      read = Set.new
      trades = []

      1.upto(MAX_TRADE_HISTORY_PAGES) do |page|
        batch = provider.fetch_trade_history_page(min_date: window_start, page: page)
        return TradeHistory.new(trades: trades, complete: true) if batch.empty?

        kept = batch.select { |trade| closed_since?(trade, window_start) }
        fresh = kept.reject { |trade| read.include?(trade_key(trade)) }
        if kept.any? && fresh.empty?
          capture_truncated_trade_history(etoro_account, window_start, trades, repeated_page: page)
          return TradeHistory.new(trades: trades, complete: false)
        end

        trades.concat(fresh)
        added = fresh.reject { |trade| stored.include?(trade_key(trade)) }
        return TradeHistory.new(trades: trades, complete: true) if added.empty?

        read.merge(fresh.map { |trade| trade_key(trade) })
      end

      capture_truncated_trade_history(etoro_account, window_start, trades)
      TradeHistory.new(trades: trades, complete: false)
    rescue Provider::Etoro::ApiError => e
      capture_partial_failure(:trade_history, e, etoro_account)
      nil
    end

    def fetch_balance_snapshots(etoro_account, account_id, today, window_start)
      return skip_after_rate_limit(:balance_history) if rate_limited?

      latest_stored = Array(etoro_account.raw_balance_history_payload).filter_map { |snapshot| parse_date(snapshot["date"]) }.max
      from_date = latest_stored ? [ latest_stored - BALANCE_HISTORY_OVERLAP_DAYS, window_start ].max : window_start

      data = provider.fetch_balance_history(account_type: TRADING_ACCOUNT_TYPE, account_id: account_id, from_date: from_date, to_date: today)
      Array(field(data, "snapshots")).filter_map { |snapshot| normalize_snapshot(snapshot, account_id) }
    rescue Provider::Etoro::ApiError => e
      capture_partial_failure(:balance_history, e, etoro_account)
      nil
    end

    # One day's figures for this account: its own breakdown, or a single one
    # naming no account. The day's totals stand in only when there is no
    # breakdown at all, since they add up every account listed; a day whose
    # breakdowns are all other accounts' is skipped.
    def normalize_snapshot(snapshot, account_id)
      date = parse_date(field(snapshot, "date"))
      return nil unless date

      breakdowns = Array(field(snapshot, "accountSnapshots"))
      own = breakdowns.find { |breakdown| field(breakdown, "accountId").to_s == account_id }
      own ||= breakdowns.first if breakdowns.one? && field(breakdowns.first, "accountId").blank?
      return nil if own.nil? && breakdowns.any?

      total, cash, currency = if own
        [ field(own, "total"), field(own, "cash"), field(own, "currency") ]
      else
        [ field(snapshot, "totalBalance"), field(snapshot, "totalCash"), field(snapshot, "totalCurrencyIso") ]
      end
      return nil if parse_decimal(total).nil?

      { "date" => date.iso8601, "total" => total.to_s, "cash" => cash&.to_s, "currency" => currency }.compact
    end

    # The cash eToro's daily balances count: the account's available cash
    # and what its copy-trading portfolios hold uninvested.
    def available_cash(balance, data)
      portfolio = field(data, "clientPortfolio") || data
      mirrored = Array(field(portfolio, "mirrors")).sum(BigDecimal("0")) { |mirror| parse_decimal(field(mirror, "availableAmount")) || 0 }

      (parse_decimal(field(field(balance, "equityDetails"), "available")) || BigDecimal("0")) + mirrored
    end

    # Records what each part of the account is worth today (see
    # EtoroPortfolioSnapshot), whatever the account is shown as, as eToro
    # keeps no past figures of a mirror. A later sync the same day replaces
    # the day's figures. A mirror no longer listed is closed, once; a
    # portfolio without a mirrors list closes none.
    def record_snapshots!(etoro_account, balance, data, today)
      portfolio = field(data, "clientPortfolio") || data
      mirrors = field(portfolio, "mirrors")
      available = parse_decimal(field(field(balance, "equityDetails"), "available")) || BigDecimal("0")

      # eToro can list a copy's positions among the user's own as well.
      own = Array(field(portfolio, "positions")).select { |position| field(position, "mirrorID").to_i == EtoroPortfolioSnapshot::OWN_POSITIONS }
      rows = [ snapshot_row(etoro_account, EtoroPortfolioSnapshot::OWN_POSITIONS, today, cash: available, positions: own) ]
      Array(mirrors).each do |mirror|
        mirror_id = field(mirror, "mirrorID").to_i
        next unless mirror_id.positive?

        rows << snapshot_row(
          etoro_account, mirror_id, today,
          cash: parse_decimal(field(mirror, "availableAmount")) || BigDecimal("0"),
          positions: field(mirror, "positions"),
          deposits: parse_decimal(field(mirror, "depositSummary")),
          withdrawals: parse_decimal(field(mirror, "withdrawalSummary")),
          username: field(mirror, "parentUsername").presence&.to_s
        )
      end
      rows.concat(closed_snapshot_rows(etoro_account, rows.map { |row| row[:mirror_id] }, today)) if mirrors.is_a?(Array)

      EtoroPortfolioSnapshot.upsert_all(rows, unique_by: %i[etoro_account_id mirror_id date])
    end

    def snapshot_row(etoro_account, mirror_id, date, cash:, positions:, deposits: nil, withdrawals: nil, username: nil)
      positions = Array(positions)
      value = positions.sum(BigDecimal("0")) { |position| position_value(position) }

      {
        etoro_account_id: etoro_account.id, mirror_id: mirror_id, date: date, closed: false,
        total: (cash + value).round(4), cash: cash.round(4), deposits: deposits, withdrawals: withdrawals,
        username: username, holdings: snapshot_holdings(etoro_account, positions)
      }
    end

    # A mirror listed on an earlier day and not today was closed: eToro sold
    # its positions and returned its money to the account's cash.
    def closed_snapshot_rows(etoro_account, listed_ids, date)
      latest_mirror_snapshots(etoro_account).filter_map do |snapshot|
        next if snapshot.closed? || listed_ids.include?(snapshot.mirror_id)

        {
          etoro_account_id: etoro_account.id, mirror_id: snapshot.mirror_id, date: date, closed: true,
          total: 0, cash: 0, deposits: snapshot.deposits, withdrawals: snapshot.withdrawals,
          username: snapshot.username, holdings: {}
        }
      end
    end

    def latest_mirror_snapshots(etoro_account)
      etoro_account.portfolio_snapshots.mirrors
        .select("DISTINCT ON (etoro_portfolio_snapshots.mirror_id) etoro_portfolio_snapshots.*")
        .order(:mirror_id, date: :desc)
        .to_a
    end

    # The real-asset positions by instrument, as the holdings import counts
    # them (see DataHelpers#real_asset?): an owned asset by its settlement
    # type, from this sync or an earlier one, or an unleveraged buy of a
    # stock, ETF or crypto when eToro sends none. An instrument eToro has not
    # described yet counts as one, as the sync describes it before the
    # holdings import runs; that part is kept as "assumed", for the days to
    # leave out once eToro describes the instrument as a CFD (see
    # EtoroAccount::CopiesProcessor#snapshot_held).
    def snapshot_holdings(etoro_account, positions)
      totals = positions.each_with_object({}) do |position, holdings|
        instrument_id = field(position, "instrumentID").to_s
        settlement_type = field(position, "settlementTypeID")
        settlement_type = (etoro_account.position_settlement_types || {})[field(position, "positionID").to_s] if settlement_type.nil?
        instrument = etoro_item.instruments_map[instrument_id]
        owned = if settlement_type.nil?
          unleveraged_long?(position) && (instrument.nil? || REAL_ASSET_TYPE_IDS.include?(instrument["type_id"]&.to_i))
        else
          settlement_type.to_i == REAL_ASSET_SETTLEMENT_TYPE
        end
        next unless owned && instrument_id.present?

        held = holdings[instrument_id] ||= Hash.new(BigDecimal("0"))
        units = parse_decimal(field(position, "units")) || 0
        value = position_value(position)
        held[:units] += units
        held[:value] += value
        if settlement_type.nil? && instrument.nil?
          held[:assumed_units] += units
          held[:assumed_value] += value
        end
      end

      totals.transform_values do |held|
        held.to_h { |key, amount| [ key.to_s, (key.to_s.end_with?("value") ? amount.round(4) : amount).to_s("F") ] }
      end
    end

    def position_value(position)
      (parse_decimal(field(position, "amount")) || BigDecimal("0")) + position_pnl(position)
    end

    # Split into copies, each mirror with a snapshot is an account to set up,
    # named after the trader copied, and one set up stays once the copy is
    # closed, with its history. One closed before it was set up is dropped,
    # and so is every one not set up once the account is no longer split:
    # their snapshots stay with the main account, for a return to copies.
    def sync_copy_accounts!(etoro_account)
      copies = etoro_account.copy_accounts.includes(:account_provider).index_by(&:mirror_id)

      unless etoro_account.shown_as_copies?
        copies.each_value { |copy| copy.destroy! if copy.account_provider.nil? }
        return
      end

      latest_mirror_snapshots(etoro_account).each do |snapshot|
        copy = copies[snapshot.mirror_id]
        if snapshot.closed? && copy&.account_provider.nil?
          copy&.destroy!
          next
        end

        copy ||= etoro_account.copy_accounts.build(etoro_item: etoro_item, mirror_id: snapshot.mirror_id, display_mode: :copies)
        copy.update!(
          etoro_account_id: "#{etoro_account.etoro_account_id}-copy-#{snapshot.mirror_id}",
          name: I18n.t("etoro_items.copies.account_name", trader: snapshot.username.presence || snapshot.mirror_id),
          account_type: "trading",
          currency: etoro_account.currency,
          current_balance: snapshot.closed? ? 0 : snapshot.total,
          cash_balance: snapshot.closed? ? 0 : snapshot.cash,
          last_positions_sync: Time.current
        )
      end
    end

    def merge_trades(existing, fetched)
      (Array(existing) + Array(fetched))
        .reverse
        .uniq { |trade| trade_key(trade) }
        .reverse
    end

    def trade_key(trade)
      [ field(trade, "positionId").to_s, field(trade, "closeTimestamp").to_s ]
    end

    def trade_keys(trades)
      Array(trades).to_set { |trade| trade_key(trade) }
    end

    def closed_since?(trade, date)
      closed_on = parse_date(field(trade, "closeTimestamp"))
      closed_on.present? && closed_on >= date
    end

    def merge_snapshots(existing, fetched)
      (Array(existing) + Array(fetched))
        .reverse
        .uniq { |snapshot| snapshot["date"] }
        .sort_by { |snapshot| snapshot["date"] }
    end

    # Asks eToro on every sync about every instrument in use, as a ticker or
    # listing can change under an instrument ID. Each field eToro answers
    # replaces the cached one, and a field it leaves out keeps the old value.
    # After a rate limit the cache is kept as it is, and the skip is reported
    # only when some instrument has no details at all.
    def refresh_instruments!(etoro_account)
      ids = instrument_ids(etoro_account)
      return if ids.empty?

      cached = etoro_item.instruments_map

      if rate_limited?
        skip_after_rate_limit(:instrument_metadata) if (ids - cached.keys).any?
        return
      end

      fetched = provider.fetch_instruments(ids.map(&:to_i)).each_with_object({}) do |instrument, map|
        id = field(instrument, "instrumentID").to_s
        next if id.blank?

        map[id] = {
          "symbol" => field(instrument, "symbolFull"),
          "name" => field(instrument, "instrumentDisplayName"),
          "type_id" => field(instrument, "instrumentTypeID"),
          "exchange_id" => field(instrument, "exchangeID")
        }.compact
      end

      merged = cached.merge(fetched) { |_id, stored, latest| stored.is_a?(Hash) ? stored.merge(latest) : latest }
      etoro_item.update!(raw_instruments_payload: merged) if merged != cached

      undescribed = ids - merged.keys
      capture_undescribed_instruments(etoro_account, undescribed) if undescribed.any?
    rescue Provider::Etoro::ApiError => e
      capture_partial_failure(:instrument_metadata, e, etoro_account)
    end

    # eToro answered without these instruments. Their positions and trades
    # are left out, and their value counts as cash, until it describes them.
    def capture_undescribed_instruments(etoro_account, ids)
      @partial_failures << {
        what: :instrument_metadata,
        message: I18n.t("etoro_items.sync.partial_failures.instruments_not_described", count: ids.size)
      }

      DebugLogEntry.capture(
        category: "sync",
        level: "warn",
        message: "EtoroItem::Importer - eToro returned no details for #{ids.size} instrument(s); their positions and trades are not imported.",
        source: "etoro",
        family: etoro_item.family,
        account_provider: etoro_account.account_provider,
        provider_key: "etoro",
        metadata: { instrument_ids: ids.first(100), count: ids.size }
      )
    end

    def instrument_ids(etoro_account)
      records = Array(etoro_account.raw_positions_payload) + Array(etoro_account.raw_trades_payload)
      records.filter_map { |record| field(record, "instrumentID")&.to_s.presence }.uniq
    end

    # Daily prices for the account's past holdings, once its instruments are
    # described (see EtoroItem::PriceHistoryImporter). Like the histories,
    # what eToro does not send now, a later sync fetches, and the positions
    # and balances saved before them stand whatever happens to them, a key
    # the price endpoints refuse among it: the account's own endpoints have
    # just taken it. An account shown by its totals fetches nothing, so it
    # hands back the securities eToro priced for it even after a rate limit.
    def import_price_history!(etoro_account)
      if rate_limited? && etoro_account.current_account && !etoro_account.shown_as_totals?
        skip_after_rate_limit(:price_history) if instrument_ids(etoro_account).any?
        return
      end

      result = EtoroItem::PriceHistoryImporter.new(etoro_item, etoro_account, provider: provider).import
      @partial_failures.concat(result.partial_failures)
      @rate_limited_at ||= result.rate_limited_at
    rescue => e
      @partial_failures << { what: :price_history, message: e.message }

      DebugLogEntry.capture(
        category: "sync",
        level: "error",
        message: "EtoroItem::Importer - Failed to import the price history: #{e.class} - #{e.message}",
        source: "etoro",
        family: etoro_item.family,
        account_provider: etoro_account.account_provider,
        provider_key: "etoro",
        metadata: { error_class: e.class.name, backtrace: Array(e.backtrace).first(5) }
      )
    end

    # eToro counts requests per user key, and both histories draw on one
    # quota. Once it throttles a fetch, the remaining ones are left to the
    # next sync rather than each waiting out a Retry-After of its own.
    def rate_limited?
      @rate_limited_at.present?
    end

    def skip_after_rate_limit(what)
      @partial_failures << { what: what, message: I18n.t("etoro_items.sync.partial_failures.skipped_after_rate_limit") }
      nil
    end

    def capture_partial_failure(what, error, etoro_account)
      @rate_limited_at ||= Time.current if error.is_a?(Provider::Etoro::RateLimitError)
      @partial_failures << { what: what, message: error.message }

      DebugLogEntry.capture(
        category: "sync",
        level: "warn",
        message: "EtoroItem::Importer - Failed to fetch #{what.to_s.humanize(capitalize: false)}: #{error.message}. Keeping the stored copy.",
        source: "etoro",
        family: etoro_item.family,
        account_provider: etoro_account.account_provider,
        provider_key: "etoro",
        metadata: { status_code: error.status_code, error_class: error.class.name }
      )
    end

    # The walk stopped at the page cap or, given `repeated_page`, at a page
    # eToro answered with trades already read.
    def capture_truncated_trade_history(etoro_account, window_start, trades, repeated_page: nil)
      @partial_failures << {
        what: :trade_history,
        message: I18n.t("etoro_items.sync.partial_failures.trade_history_truncated", pages: repeated_page ? repeated_page - 1 : MAX_TRADE_HISTORY_PAGES)
      }

      reason = repeated_page ? "page #{repeated_page} repeated trades already read" : "it still had trades after #{MAX_TRADE_HISTORY_PAGES} pages"
      DebugLogEntry.capture(
        category: "sync",
        level: "warn",
        message: "EtoroItem::Importer - Trade history stopped as #{reason}; older trades were not fetched.",
        source: "etoro",
        family: etoro_item.family,
        account_provider: etoro_account.account_provider,
        provider_key: "etoro",
        metadata: {
          min_date: window_start.iso8601,
          pages: repeated_page ? repeated_page - 1 : MAX_TRADE_HISTORY_PAGES,
          trades: trades.size,
          oldest_close: trades.filter_map { |trade| field(trade, "closeTimestamp") }.min
        }
      )
    end
end
