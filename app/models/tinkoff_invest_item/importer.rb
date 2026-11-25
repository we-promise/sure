class TinkoffInvestItem::Importer
  include TinkoffInvestAccount::DataHelpers

  LOOKBACK_DAYS = 7.days
  DEFAULT_HISTORY_START = Time.utc(2015, 1, 1).freeze
  OPEN_STATUSES = %w[ACCOUNT_STATUS_OPEN OPEN].freeze
  NO_ACCESS_LEVEL = "ACCOUNT_ACCESS_LEVEL_NO_ACCESS".freeze

  attr_reader :tinkoff_invest_item, :provider

  def initialize(tinkoff_invest_item, provider:)
    @tinkoff_invest_item = tinkoff_invest_item
    @provider = provider
  end

  def import
    accounts = provider.fetch_accounts
    open_accounts = accounts.select { |acct| eligible_account?(acct) }
    account_ids = open_accounts.filter_map { |acct| acct["id"]&.to_s.presence }

    open_accounts.each do |acct|
      import_account(acct) if acct["id"].present?
    end

    remove_unlinked_accounts_missing_from(account_ids)
    tinkoff_invest_item.update!(status: :good, raw_accounts_payload: accounts)
  rescue Provider::TinkoffInvest::PortfolioClient::AuthenticationError
    tinkoff_invest_item.update!(status: :requires_update)
    raise
  end

  private

    def eligible_account?(acct)
      status = acct["status"].to_s.upcase
      access = acct["accessLevel"].to_s.upcase
      (status.blank? || OPEN_STATUSES.include?(status)) && access != NO_ACCESS_LEVEL
    end

    def import_account(acct)
      account_id = acct["id"].to_s
      fetch_to = Time.current.utc
      portfolio = provider.fetch_portfolio(account_id, currency: "RUB")

      total_balance, currency = parse_money(portfolio["totalAmountPortfolio"], tinkoff_invest_item.family.currency || "RUB")
      cash_balance, = parse_money(portfolio["totalAmountCurrencies"], currency)

      enriched_portfolio = enrich_portfolio(portfolio, currency).merge("_fetched_at" => fetch_to.iso8601)

      tinkoff_account = tinkoff_invest_item.tinkoff_invest_accounts.find_or_initialize_by(
        tinkoff_invest_account_id: account_id
      )
      prior_pending_cursor = tinkoff_account.raw_portfolio_payload&.dig("_pending_cursor").presence
      tinkoff_account.assign_attributes(
        name: acct["name"].presence || I18n.t("tinkoff_invest_items.defaults.account_name", id: account_id),
        account_type: acct["type"].presence,
        account_status: acct["status"].presence,
        currency: currency,
        current_balance: total_balance || BigDecimal("0"),
        cash_balance: cash_balance || BigDecimal("0"),
        raw_payload: acct,
        raw_portfolio_payload: enriched_portfolio
      )

      if tinkoff_account.persisted? && tinkoff_account.current_account.present?
        ops_result = provider.fetch_operations(
          account_id,
          from: operations_from_time(tinkoff_account, acct),
          to: fetch_to
        )
        enriched_ops = enrich_operations(ops_result[:items], currency)
        merged_ops = merge_retained_operations(tinkoff_account.raw_operations_payload, enriched_ops)

        # Hold last_synced_at and operations_cursor until Processor succeeds
        # so a failure between import and processing never loses operations.
        tinkoff_account.assign_attributes(
          raw_operations_payload: merged_ops,
          raw_portfolio_payload: enriched_portfolio.merge(
            "_pending_cursor" => ops_result[:next_cursor].presence || prior_pending_cursor || tinkoff_account.operations_cursor
          ).compact
        )
      end

      tinkoff_account.save!
    end

    def operations_from_time(tinkoff_account, raw_acct)
      sync_start = tinkoff_invest_item.sync_start_date&.utc
      if tinkoff_account.last_synced_at.present?
        lookback = (tinkoff_account.last_synced_at - LOOKBACK_DAYS).utc
        return sync_start && sync_start > lookback ? sync_start : lookback
      end

      return sync_start if sync_start

      parse_time(raw_acct["openedDate"]) || DEFAULT_HISTORY_START
    end

    def parse_time(raw)
      return nil if raw.blank?

      Time.iso8601(raw.to_s).utc
    rescue ArgumentError
      nil
    end

    def enrich_portfolio(portfolio, fallback_currency)
      positions = Array(portfolio["positions"]).map do |pos|
        itype = normalize_instrument_type(pos["instrumentType"])
        next pos if itype == "currency"

        _, price_ccy = parse_money(pos["currentPrice"], fallback_currency)
        meta = resolve_instrument_meta(
          instrument_uid: pos["instrumentUid"],
          figi: pos["figi"],
          ticker_hint: pos["ticker"],
          instrument_type_hint: itype,
          currency_hint: price_ccy
        )
        meta ? pos.merge("resolved_instrument" => serialize_meta(meta)) : pos
      end

      portfolio.merge("positions" => positions)
    end

    def enrich_operations(operations, fallback_currency)
      Array(operations).map do |op|
        uid = op["instrumentUid"].presence
        figi = op["figi"].presence
        ticker_hint = op["ticker"].presence
        next op unless uid || figi || ticker_hint

        _, op_ccy = parse_money(op["payment"], fallback_currency)
        meta = resolve_instrument_meta(
          instrument_uid: uid,
          figi: figi,
          ticker_hint: ticker_hint,
          instrument_type_hint: op["instrumentType"].presence || op["instrumentKind"].presence,
          name_hint: op["name"].presence || op["description"].presence,
          currency_hint: op_ccy
        )
        meta ? op.merge("resolved_instrument" => serialize_meta(meta)) : op
      end
    end

    def resolve_instrument_meta(instrument_uid: nil, figi: nil, ticker_hint: nil, instrument_type_hint: nil, name_hint: nil, currency_hint: nil)
      provider.resolve_instrument(
        instrument_uid: instrument_uid,
        figi: figi,
        ticker_hint: ticker_hint,
        instrument_type_hint: instrument_type_hint,
        name_hint: name_hint,
        currency_hint: currency_hint
      )
    end

    def serialize_meta(meta)
      {
        "uid" => meta.uid,
        "figi" => meta.figi,
        "ticker" => meta.ticker,
        "name" => meta.name,
        "instrument_type" => meta.instrument_type,
        "currency" => meta.currency,
        "exchange_operating_mic" => meta.exchange_operating_mic,
        "country_code" => meta.country_code,
        "nominal" => meta.nominal&.to_s("F"),
        "initial_nominal" => meta.initial_nominal&.to_s("F"),
        "amortization_flag" => meta.amortization_flag,
        "logo_url" => meta.logo_url
      }.compact
    end

    def merge_retained_operations(existing_ops, fresh_ops)
      existing = Array(existing_ops)
      return fresh_ops if existing.empty?

      fresh_ids = fresh_ops.filter_map { |op| op["id"]&.to_s.presence }.to_set
      retained = existing.reject do |op|
        op_id = op["id"]&.to_s.presence
        op_id && fresh_ids.include?(op_id)
      end
      fresh_ops + retained
    end

    def remove_unlinked_accounts_missing_from(account_ids)
      scope = tinkoff_invest_item.unlinked_tinkoff_invest_accounts
      scope = scope.where.not(tinkoff_invest_account_id: account_ids) if account_ids.any?
      scope.destroy_all
    end
end
