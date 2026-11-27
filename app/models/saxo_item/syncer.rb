class SaxoItem::Syncer
  include SyncStats::Collector

  def initialize(item)
    @item = item
  end

  def perform_sync(sync)
    SaxoItem::Importer.new(@item).import(sync)
    collect_setup_stats(sync, provider_accounts: @item.saxo_accounts)
    account_ids = @item.accounts.pluck(:id)
    collect_transaction_stats(sync, account_ids: account_ids, source: "saxo")
    collect_trades_stats(sync, account_ids: account_ids, source: "saxo")
    collect_health_stats(sync)
  rescue StandardError => error
    @item.update!(status: :requires_update) if error.is_a?(Provider::Saxo::AuthenticationError)
    DebugLogEntry.capture(
      category: "provider_sync_error",
      level: "error",
      message: error.message,
      source: self.class.name,
      provider_key: "saxo",
      family: @item.family,
      account_provider_id: error.is_a?(Provider::Saxo::Error) ? error.diagnostic[:account_provider_id] : nil,
      metadata: { saxo_item_id: @item.id }.merge(error.is_a?(Provider::Saxo::Error) ? error.diagnostic : {})
    )
    collect_health_stats(sync, errors: [ { message: error.message, category: "sync_error" } ])
    raise
  end

  def perform_post_sync
  end
end
