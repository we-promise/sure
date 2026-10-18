class DirectaItem::Syncer
  def initialize(item)
    @item = item
  end

  def perform_sync(sync)
    generation = @item.connection_generation
    unless @item.ready_for_sync?
      raise DirectaItem::PortfolioNormalizer::Error.new(:sync_failed)
    end

    snapshot = @item.provider.fetch_portfolio_snapshot
    DirectaItem::Importer.new(@item).import(
      snapshot: snapshot,
      parent_sync: sync,
      window_start_date: sync.window_start_date,
      window_end_date: sync.window_end_date
    )
  rescue DirectaItem::PortfolioNormalizer::Error => error
    expected_generation = snapshot&.connection_generation || generation
    record_sync_failure(error.code, expected_generation: expected_generation)
    capture_failure(error.code)
    raise
  rescue Provider::Directa::AuthenticationError
    require_update!(expected_generation: generation)
    record_sync_failure("sync_failed", expected_generation: generation)
    capture_failure("sync_failed")
    raise DirectaItem::PortfolioNormalizer::Error.new(:sync_failed), cause: nil
  rescue StandardError
    expected_generation = snapshot&.connection_generation || generation
    record_sync_failure("sync_failed", expected_generation: expected_generation)
    capture_failure("sync_failed")
    raise DirectaItem::PortfolioNormalizer::Error.new(:sync_failed), cause: nil
  end

  def perform_post_sync
  end

  private

    def record_sync_failure(code, expected_generation:)
      return unless @item.persisted? && expected_generation
      return unless ActiveRecordEncryptionConfig.explicitly_configured?

      @item.with_lock do
        @item.record_sync_failure!(code) if @item.connection_generation == expected_generation
      end
    end

    def require_update!(expected_generation:)
      @item.with_lock do
        @item.update!(status: :requires_update) if @item.connection_generation == expected_generation
      end
    end

    def capture_failure(code)
      DebugLogEntry.capture(
        category: "provider_sync",
        level: "warn",
        message: "Directa sync failed with #{code}.",
        source: "directa",
        family: @item.family,
        provider_key: "directa",
        metadata: { item_id: @item.id, error_code: code }
      )
    end
end
