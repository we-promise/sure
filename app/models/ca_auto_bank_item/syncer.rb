class CaAutoBankItem::Syncer
  def initialize(item)
    @item = item
  end

  def perform_sync(sync)
    generation = @item.connection_generation
    raise Provider::CaAutoBank::Error.new(:session_expired) unless @item.ready_for_sync?

    snapshot = @item.provider.fetch_snapshot(identity: @item.account_identity, generation: generation)
    CaAutoBankItem::Importer.new(@item).import(snapshot: snapshot, parent_sync: sync,
      window_start_date: sync.window_start_date, window_end_date: sync.window_end_date)
  rescue Provider::CaAutoBank::Error => error
    record_failure(error.code, generation)
    raise
  rescue StandardError
    record_failure("sync_failed", generation)
    raise Provider::CaAutoBank::Error.new(:sync_failed), cause: nil
  end

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
      DebugLogEntry.capture(category: "provider_sync", level: "warn", source: "ca_auto_bank",
        provider_key: "ca_auto_bank", family: @item.family, message: "CA Auto Bank snapshot could not be synchronized.",
        metadata: { item_id: @item.id, error_code: safe_code })
    end
end
