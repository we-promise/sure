class CaAutoBankItem::Syncer
  def initialize(item)
    @item = item
  end

  def perform_sync(sync)
    result = @item.with_provider_sync_lock { perform_locked(sync) }
    return unless result

    result
  end

  def perform_locked(sync)
    @item.reload
    generation = nil
    generation = @item.connection_generation
    return if @item.sync_cooldown?
    raise Provider::CaAutoBank::Error.new(:session_expired) unless @item.ready_for_sync?
    return unless @item.reserve_sync_attempt!

    snapshot = @item.provider.fetch_snapshot(identity: @item.account_identity, generation: generation)
    result = CaAutoBankItem::Importer.new(@item).import(
      snapshot: snapshot,
      parent_sync: sync,
      window_start_date: sync.window_start_date,
      window_end_date: sync.window_end_date
    )
    @item.clear_sync_rate_limit!
    result
  rescue Provider::CaAutoBank::Error => error
    if error.code == "rate_limited"
      @item.record_rate_limit!(
        retry_after: error.retry_after,
        expected_generation: generation,
        updates: { last_sync_error_code: "rate_limited" }
      )
      capture_failure("rate_limited")
      return
    end

    record_failure(error.code, generation)
    raise
  rescue StandardError
    record_failure("sync_failed", generation)
    raise Provider::CaAutoBank::Error.new(:sync_failed), cause: nil
  end

  private :perform_locked

  def perform_post_sync
  end

  private

    def record_failure(code, generation)
      safe_code = CaAutoBankItem::ERROR_CODES.include?(code) ? code : "sync_failed"
      @item.with_lock do
        if @item.connection_generation == generation
          changes = { last_sync_error_code: safe_code }
          if %w[session_expired invalid_session].include?(safe_code)
            changes.merge!(status: :requires_update, authentication_token: nil, session_expires_at: nil)
          end
          @item.update!(changes)
        end
      end
      capture_failure(safe_code)
    end

    def capture_failure(code)
      DebugLogEntry.capture(category: "provider_sync", level: "warn", source: "ca_auto_bank",
        provider_key: "ca_auto_bank", family: @item.family, message: "CA Auto Bank snapshot could not be synchronized.",
        metadata: { item_id: @item.id, error_code: code })
    end
end
