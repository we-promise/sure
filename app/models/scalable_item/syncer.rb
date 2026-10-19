class ScalableItem::Syncer
  def initialize(item)
    @item = item
  end

  def perform_sync(sync)
    return if @item.next_sync_at.present? && @item.next_sync_at > Time.current

    unless @item.ready_for_sync?
      @item.with_authenticated_provider { nil }
      return
    end
    return unless @item.sync_due?

    @item.with_authenticated_provider do |provider|
      person_id = provider.person_identity.to_s
      raise Provider::Scalable::Error.new(:account_identity_changed) if person_id.blank? || person_id != @item.person_identity.to_s

      discovery = provider.read(
        :broker_portfolios,
        variables: { "id" => person_id }
      )
      account = discovery.is_a?(Hash) ? discovery["account"] : nil
      account_id = account.is_a?(Hash) ? account["id"] : nil
      portfolio_rows = account.is_a?(Hash) ? account["brokerPortfolios"] : nil
      unless account_id.is_a?(String) && account_id.present? && portfolio_rows.is_a?(Array) && portfolio_rows.any?
        raise Provider::Scalable::Error.new(:unsupported_account)
      end

      ids = portfolio_rows.filter_map do |row|
        row["id"] if row.is_a?(Hash) && row["id"].is_a?(String) && row["id"].present?
      end
      if ids.length != portfolio_rows.length || ids.uniq.length != ids.length
        raise Provider::Scalable::Error.new(:invalid_snapshot)
      end

      fetched_at = Time.current
      responses = ids.map do |portfolio_id|
        variables = { "accountId" => account_id, "portfolioId" => portfolio_id }
        {
          "portfolio_id" => portfolio_id,
          "overview" => provider.read(
            :broker_overview,
            variables: variables.merge("includeYearToDate" => false)
          ),
          "cash_breakdown" => provider.read(
            :broker_cash_breakdown,
            variables: variables
          ),
          "holdings" => provider.read(
            :broker_holdings,
            variables: variables.merge("includeYearToDate" => false, "quoteSource" => nil)
          )
        }
      end
      snapshot = ScalableItem::PortfolioNormalizer.new(now: fetched_at).normalize(
        discovery: discovery,
        portfolio_responses: responses,
        person_identity: person_id,
        connection_generation: @item.connection_generation,
        fetched_at: fetched_at
      )

      ScalableItem::Importer.new(@item).import(
        snapshot: snapshot,
        parent_sync: sync,
        window_start_date: sync&.window_start_date,
        window_end_date: sync&.window_end_date
      )

      sync_history(provider, account_id)
    end
  end

  def perform_post_sync
  end

  private

    def sync_history(provider, account_id)
      @item.scalable_accounts.order(:id).each do |provider_account|
        ApplicationRecord.transaction(requires_new: true) do
          rows = ScalableItem::HistoryReader.new(
            provider: provider, account_id: account_id, portfolio_id: provider_account.uid
          ).read
          normalized = ScalableItem::HistoryNormalizer.new(rows: rows, portfolio_id: provider_account.uid).normalize
          verify_history_cash!(provider, account_id, provider_account)
          ScalableItem::HistoryImporter.new(@item).import(provider_account: provider_account, normalized: normalized)
        end
      end
    rescue Provider::Scalable::Error => error
      raise if %w[session_expired authentication_failed account_identity_changed].include?(error.code)

      @item.reload
      code = %w[history_incomplete history_changed history_unsupported rate_limited provider_unavailable].include?(error.code) ? error.code : "history_incomplete"
      attributes = { last_sync_error_code: code }
      attributes[:next_sync_at] = 15.minutes.from_now if %w[rate_limited provider_unavailable].include?(code)
      @item.update!(attributes)
      DebugLogEntry.capture(
        category: "provider_sync_error", level: "warn", source: self.class.name,
        provider_key: "scalable", family: @item.family,
        message: "Scalable cash history import was not completed.", metadata: { error_code: code }
      )
    end

    def verify_history_cash!(provider, account_id, provider_account)
      response = provider.read(:broker_cash_breakdown,
        variables: { "accountId" => account_id, "portfolioId" => provider_account.uid })
      account = response["account"] if response.is_a?(Hash)
      portfolio = account["brokerPortfolio"] if account.is_a?(Hash)
      cash = portfolio.dig("payments", "buyingPower") if portfolio.is_a?(Hash)
      unless account.is_a?(Hash) && account["id"] == account_id && portfolio.is_a?(Hash) &&
          portfolio["id"] == provider_account.uid && cash.is_a?(Hash)
        raise Provider::Scalable::Error.new(:history_incomplete)
      end

      cash_balance = BigDecimal(cash.fetch("cashBalance").to_s)
      loaned = BigDecimal(cash.fetch("loaned").to_s)
      unless cash_balance.finite? && cash_balance == provider_account.cash_balance && loaned.finite? && loaned.zero?
        raise Provider::Scalable::Error.new(:history_changed)
      end
    rescue ArgumentError, TypeError, KeyError
      raise Provider::Scalable::Error.new(:history_incomplete), cause: nil
    end
end
