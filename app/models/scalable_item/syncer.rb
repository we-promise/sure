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
    end
  end

  def perform_post_sync
  end
end
