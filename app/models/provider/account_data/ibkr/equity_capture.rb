# Derive history from an explicitly named original inventory artifact. The caller
# supplies its existing lease fence; there is no HTTP or market-data lookup here.
class Provider::AccountData::Ibkr::EquityCapture
  def initialize(connection:, sync:, source_batch_id:, external_account:, writer_epoch:, fence:)
    @connection, @sync, @source_batch_id, @external = connection, sync, source_batch_id, external_account
    @writer_epoch, @fence = writer_epoch, fence
    raise ArgumentError unless writer_epoch.is_a?(Integer) && writer_epoch >= 0 && fence.respond_to?(:call)
  end

  def capture!
    source = Provider::AccountData::Ibkr::Archive.resolve(connection: @connection, sync: @sync,
      observed_at: @sync.created_at, source_batch_id: @source_batch_id)
    export, inventory_batch = source.values_at(:export, :batch)
    account = @external.current_account
    unless account && account.family_id == @connection.family_id && @external.family_id == @connection.family_id &&
        @external.provider_connection_id == @connection.id && @external.provider_key == "ibkr"
      raise Provider::AccountData::InvalidResponse, "IBKR equity account does not belong to the export connection"
    end
    policy = Account::SourcePolicy.active.find_by!(account: account, resource: "historical_balances")
    initial_link = @external.account_provider
    raise Provider::AccountData::StaleWriter, "IBKR does not own historical balances" unless policy.account_provider_id == initial_link&.id
    link_revision = initial_link.lock_version
    reader = Provider::AccountData::Ibkr.new(client: nil, observed_at: @sync.created_at, timezone: export.scope.fetch("timezone"),
      export_scope: export.scope, staged_export: export.payload)
    data = export.statement.accounts.find { |row| row.fetch("external_id") == @external.external_id }
    raise Provider::AccountData::InvalidResponse, "IBKR export does not contain this account" unless data
    record = reader.normalize_account(data)
    raise Provider::AccountData::InvalidResponse, "IBKR equity base currency differs from the financial account" unless record[:currency] == account.currency
    equity = reader.historical_equity(account: record)
    snapshot = Provider::AccountData::Ibkr::EquitySnapshot.new(external_id: record[:external_id], currency: equity.fetch(:currency),
      equity_rows: equity.fetch(:rows), statement_sha256: equity.fetch(:statement_sha256), observed_on: Date.iso8601(export.scope.fetch("observed_on")),
      imported_current_balance: record[:balance], source_artifact: { "inventory_batch_id" => inventory_batch.id,
        "inventory_payload_sha256" => Ingestion::HistoricalBalances.fingerprint(inventory_batch.payload), "provider_sync_id" => @sync.id,
        "account_provider_id" => initial_link.id, "account_provider_revision" => link_revision })
    batch = @fence.call do
      @connection.reload
      control = @connection.provider_migration_control
      unless @connection.good? && !@connection.scheduled_for_deletion && @connection.writer_epoch == @writer_epoch && (control.nil? || control.native_owned?)
        raise Provider::AccountData::StaleWriter, "IBKR equity capture lost its writer epoch"
      end
      Provider::AccountData::Ibkr::EquityHandoff.with_inventory_grant(connection: @connection, inventory_batch: inventory_batch, sync: @sync) do
        account.with_lock do
          @external.lock!
          link = AccountProvider.where(external_account_id: @external.id).lock.find_by(id: initial_link.id)
          current = Account::SourcePolicy.active.lock.find_by(account: account, resource: "historical_balances")
          unless link&.account_id == account.id && link.lock_version == link_revision && current&.id == policy.id &&
              current.account_provider_id == link.id && account.currency == record[:currency]
            raise Provider::AccountData::StaleWriter, "IBKR equity source selection changed"
          end
          key = [ "ibkr-equity", @sync.id, @external.id, inventory_batch.id, policy.id, link_revision ].join(":")
          captured = @connection.ingestion_batches.find_or_initialize_by(idempotency_key: key)
          if captured.persisted?
            raise Provider::AccountData::InvalidResponse, "IBKR equity capture conflicts with saved evidence" unless captured.payload == snapshot.payload
            Provider::AccountData::Ibkr::EquityHandoff.assert_source_current!(account: account, external_account: @external,
              source_batch: captured, require_selection: false)
          else
            captured.assign_attributes(family: @connection.family, sync: @sync, external_account: @external,
              origin_kind: "provider", stream: "equity_snapshots", scope_key: "account:#{@external.id}", mode: "snapshot", complete: true,
              writer_epoch: @writer_epoch, source_policy_version: policy.id, payload: snapshot.payload,
              coverage: { "end" => export.scope.fetch("observed_on"), "inventory_batch_id" => inventory_batch.id })
            captured.save!
          end
          captured
        end
      end
    end
    Provider::AccountData::Ibkr::EquityHandoff.new("version" => 1, "family_id" => account.family_id, "account_id" => account.id,
      "provider_connection_id" => @connection.id, "provider_sync_id" => @sync.id, "external_account_id" => @external.id,
      "account_provider_id" => policy.account_provider_id, "account_provider_revision" => link_revision, "source_batch_id" => batch.id, "inventory_batch_id" => inventory_batch.id,
      "source_policy_version" => policy.id, "writer_epoch" => batch.writer_epoch, "observed_on" => export.scope.fetch("observed_on"),
      "statement_sha256" => export.statement.fingerprint, "equity_payload_sha256" => Ingestion::HistoricalBalances.fingerprint(batch.payload))
  rescue StandardError => error
    DebugLogEntry.capture(category: "provider_sync_error", level: "warn", message: "IBKR historical source capture did not complete",
      source: self.class.name, provider_key: "ibkr", family: @connection.family, account_provider: @external.account_provider,
      metadata: { provider_connection_id: @connection.id, external_account_id: @external.id, sync_id: @sync.id, error_class: error.class.name })
    raise
  end
end
