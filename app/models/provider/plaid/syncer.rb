# Connection-framework syncer for Plaid. Mirrors Provider::Truelayer::Syncer's
# shape but calls into Plaid-specific sub-processors (which read from the
# provider_accounts.raw_*_payload columns populated by the importer).
class Provider::Plaid::Syncer
  include SyncStats::Collector

  def initialize(connection)
    @connection = connection
  end

  # Lightweight discovery for the post-OAuth callback — populates
  # provider_accounts but doesn't run sync. Called by Provider::Connection
  # via discover_accounts!.
  def discover_accounts_only
    @connection.update!(metadata: @connection.metadata.merge(
      "billed_products"    => item_response.item.billed_products,
      "available_products" => item_response.item.available_products,
      "institution_id"     => item_response.item.institution_id
    ))

    snapshot = Provider::Plaid::AccountsSnapshot.new(@connection, plaid_provider: client)
    seen_external_ids = []
    snapshot.accounts.each do |raw_account|
      seen_external_ids << raw_account.account_id
      provider_account = @connection.provider_accounts.find_or_initialize_by(external_id: raw_account.account_id)
      payload = raw_account.to_hash || {}
      payload = payload.except("disappeared_at", :disappeared_at) if payload.is_a?(Hash)
      provider_account.update!(
        external_name:    raw_account.name,
        external_type:    raw_account.type,
        external_subtype: raw_account.subtype,
        currency:         raw_account.balances&.iso_currency_code || raw_account.balances&.unofficial_currency_code,
        raw_payload:      payload
      )
    end
    mark_disappeared_accounts(seen_external_ids)
  end

  # Flags provider_accounts whose external_id no longer appears in the
  # upstream accounts response. See Provider::Truelayer::Syncer for the same
  # pattern; UI consumers (setup, show) check Provider::Account#disappeared?.
  def mark_disappeared_accounts(seen_external_ids)
    # `.where.not(col: [])` returns ALL rows in Rails 7.2 (`WHERE TRUE`).
    # Without this guard a malformed or empty upstream response would flip
    # every existing provider_account to "disappeared". Trade-off: a user
    # who legitimately closed every Plaid-linked account in one go won't
    # see them flagged here — they'd still see the connection sitting
    # account-less, which is the dominant signal anyway.
    return if seen_external_ids.empty? && @connection.provider_accounts.exists?

    stale = @connection.provider_accounts.where.not(external_id: seen_external_ids)
    stale.find_each do |pa|
      next if pa.raw_payload.is_a?(Hash) && pa.raw_payload["disappeared_at"].present?
      pa.update!(raw_payload: (pa.raw_payload || {}).merge("disappeared_at" => Time.current.iso8601))
    end
  end

  def perform_sync(sync)
    token = @connection.auth.fresh_access_token

    # Phase 1: Import latest item-level data (institution metadata, item state)
    item     = client.get_item(token).item
    inst     = client.get_institution(item.institution_id).institution
    @connection.update!(metadata: @connection.metadata.merge(
      "billed_products"      => item.billed_products,
      "available_products"   => item.available_products,
      "institution_id"       => item.institution_id,
      "raw_item_payload"     => item.to_hash,
      "raw_institution_payload" => inst.to_hash
    ))

    # Phase 2: Pull all per-account data (transactions, investments, liabilities)
    # and upsert into raw_*_payload columns on provider_accounts.
    snapshot = Provider::Plaid::AccountsSnapshot.new(@connection, plaid_provider: client)

    Provider::Connection.transaction do
      snapshot.accounts.each do |raw_account|
        provider_account = @connection.provider_accounts.find_or_initialize_by(external_id: raw_account.account_id)
        Provider::Plaid::AccountImporter.new(
          provider_account,
          account_snapshot: snapshot.get_account_data(raw_account.account_id)
        ).import
      end
      # Persist the next cursor so subsequent syncs are incremental.
      cursor = snapshot.transactions_cursor
      if cursor.present?
        @connection.update!(metadata: @connection.metadata.merge("next_cursor" => cursor))
      end
    end

    collect_setup_stats(sync, provider_accounts: @connection.provider_accounts)

    # Phase 3: Run the per-account processor on every linked provider_account.
    # Unlinked (account_id nil) and skipped accounts are ignored.
    linked = @connection.provider_accounts.where.not(account_id: nil).where(skipped: false).includes(:account)
    linked.each do |pa|
      Provider::Plaid::AccountProcessor.new(pa).process
      pa.update!(last_synced_at: Time.current)
      collect_transaction_stats(sync, account_ids: [ pa.account_id ], source: "plaid")
    end

    @connection.update!(status: :healthy, last_synced_at: Time.current, sync_error: nil)
  rescue Plaid::ApiError => e
    handle_plaid_error(e)
  rescue Provider::Auth::ReauthRequiredError
    @connection.update!(status: :requires_update, sync_error: "reauth_required")
  rescue => e
    @connection.update!(sync_error: e.message)
    raise
  ensure
    collect_health_stats(sync)
  end

  def perform_post_sync; end

  private

    def client
      Provider::Registry.plaid_provider_for_region(region)
    end

    def region
      (@connection.metadata["region"] || "us").to_sym
    end

    def item_response
      @item_response ||= client.get_item(@connection.credentials["access_token"])
    end

    # Plaid surfaces login-required as an ITEM_LOGIN_REQUIRED error code in
    # the response body. Mark the connection requires_update and return
    # without raising — Sidekiq retry would just fail again.
    def handle_plaid_error(error)
      body = JSON.parse(error.response_body) rescue {}
      if body["error_code"] == "ITEM_LOGIN_REQUIRED"
        @connection.auth.mark_requires_update!(reason: "ITEM_LOGIN_REQUIRED")
      else
        @connection.update!(sync_error: error.message)
        raise error
      end
    end
end
