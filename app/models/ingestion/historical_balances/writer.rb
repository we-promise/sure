# A child account sync may run after the provider worker released its HTTP lease.
# Captured source identity and selection fences still apply. Lock connection,
# captured grant, account, source, link, policies, batches, then financial inputs;
# no external I/O occurs inside it.
class Ingestion::HistoricalBalances::Writer
  def initialize(batch:)
    @batch = batch
  end

  def apply!
    command = Ingestion::HistoricalBalances::Command.load(@batch.payload)
    connection = @batch.provider_connection
    raise Provider::AccountData::InvalidResponse, "Historical command has no connection" unless connection
    application = connection.with_lock do
      account = connection.family.accounts.find(command[:account_id])
      source = connection.ingestion_batches.where(family_id: account.family_id, external_account_id: command[:external_account_id]).find(command[:source_batch_id])
      Provider::AccountData::Ibkr::EquityHandoff.with_source_grant(source_batch: source) do
        account.with_lock do
          assert_owner!(connection, account, command)
          @batch.lock!
          Ingestion::HistoricalBalances::SourceBinding.index!(batch: @batch)
          @batch.reload
          Ingestion::HistoricalBalances::SourceBinding.verify!(batch: @batch)
          unless @batch.payload == command.payload
            raise Provider::AccountData::InvalidResponse, "Historical command changed before publication"
          end
          return result(command, replay: true) if @batch.applied?
          current = Ingestion::HistoricalBalances::Inputs.capture(account, lock: true)
          unless Ingestion::HistoricalBalances.fingerprint(current) == command[:inputs_sha256]
            raise Provider::AccountData::StaleWriter, "Financial inputs changed after historical balance capture"
          end
          @batch.update!(status: "applying", error_code: nil)
          repair_anchor(account, command[:opening_anchor]) if command[:opening_anchor]
          if command[:rows].any?
            now = Time.current
            rows = command[:rows].map { |row| row.merge(account_id: account.id, created_at: now, updated_at: now) }
            account.balances.upsert_all(rows, unique_by: %i[account_id date currency],
              update_only: [ *Ingestion::HistoricalBalances::MONEY_COLUMNS, :flows_factor, :updated_at ])
          end
          @batch.update!(status: "applied", applied_at: Time.current, error_code: nil)
          result(command, replay: false)
        end
      end
    end
    capture_partial(command) if command[:failed_fx_dates].any?
    application
  rescue StandardError => error
    capture_failure(error)
    raise
  end

  private
    def assert_owner!(connection, account, command)
      control = ProviderMigrationControl.find_by(provider_connection_id: connection.id)
      unless connection.good? && !connection.scheduled_for_deletion &&
          (control.nil? || control.native_owned?)
        raise Provider::AccountData::StaleWriter, "Historical balance source no longer owns the writer epoch"
      end
      external = connection.external_accounts.where(family_id: account.family_id).lock.find(command[:external_account_id])
      link = AccountProvider.where(external_account_id: external.id).lock.find_by(id: command[:account_provider_id])
      policies = Account::SourcePolicy.active.where(account: account, resource: %w[historical_balances balances]).order(:id).lock.index_by(&:resource)
      policy = policies["historical_balances"]
      unless link&.id == command[:account_provider_id] && link.account_id == account.id && link.family_id == account.family_id &&
          link.lock_version == command[:account_provider_revision] &&
          policy&.id == command[:source_policy_version] && policy.account_provider_id == link.id
        raise Provider::AccountData::StaleWriter, "Historical balance source selection changed"
      end
      if command[:opening_anchor]
        balance_policy = policies["balances"]
        unless balance_policy&.id == command[:anchor_policy_version] && balance_policy.account_provider_id == link.id
          raise Provider::AccountData::StaleWriter, "Opening-anchor source selection changed"
        end
      end
      unless @batch.origin_kind == "provider" && @batch.family_id == account.family_id && command[:family_id] == account.family_id &&
          @batch.provider_connection_id == command[:provider_connection_id] && @batch.external_account_id == external.id &&
          @batch.source_policy_version == policy.id && @batch.writer_epoch == command[:writer_epoch] &&
          @batch.stream == command.stream && @batch.scope_key == "account:#{external.id}" && @batch.mode == "snapshot" &&
          @batch.schema_version == 1 && @batch.complete? == command[:failed_fx_dates].empty? && %w[captured failed applied].include?(@batch.status)
        raise Provider::AccountData::InvalidResponse, "Historical command ownership does not match its captured batch"
      end
      source = connection.ingestion_batches.where(family_id: account.family_id, external_account_id: external.id).lock.find(command[:source_batch_id])
      unless source.origin_kind == "provider" && source.stream == "equity_snapshots" && source.mode == "snapshot" && source.complete? &&
          source.scope_key == "account:#{external.id}" &&
          %w[captured applied].include?(source.status) && source.sync_id == @batch.sync_id && source.writer_epoch == command[:writer_epoch] &&
          source.source_policy_version == policy.id && Ingestion::HistoricalBalances.fingerprint(source.payload) == command[:source_sha256]
        raise Provider::AccountData::InvalidResponse, "Historical command source evidence changed"
      end
      Provider::AccountData::Ibkr::EquityHandoff.assert_source_current!(account: account,
        external_account: external, source_batch: source)
    end

    def repair_anchor(account, change)
      entry = account.entries.find(change.fetch("entry_id"))
      unless entry.valuation? && entry.valuation.opening_anchor? && !entry.protected_from_sync? && !entry.reconciled? &&
          %w[amount date currency].none? { |key| entry.locked?(key) } && entry.amount == change.fetch("amount") &&
          entry.date == change.fetch("date") && entry.currency == change.fetch("currency")
        raise Provider::AccountData::StaleWriter, "Opening anchor changed after its repair was captured"
      end
      result = Account::OpeningBalanceManager.new(account).set_opening_balance(balance: change.fetch("replacement"), date: change.fetch("date"))
      raise Provider::AccountData::InvalidResponse, "Default opening anchor could not be repaired" unless result.success?
    end

    def result(command, replay:)
      { applied_rows: command[:rows].size, anchor_repaired: command[:opening_anchor].present?, replay: replay,
        failed_fx_dates: command[:failed_fx_dates], protected_dates: command[:protected_dates] }
    end

    def capture_failure(error)
      DebugLogEntry.capture(category: "provider_sync_error", level: "warn", message: "Historical balance application did not complete",
        source: self.class.name, provider_key: @batch.provider_connection&.provider_key, family: @batch.family,
        account_provider: @batch.external_account&.account_provider,
        metadata: { ingestion_batch_id: @batch.id, external_account_id: @batch.external_account_id, error_class: error.class.name })
    end

    def capture_partial(command)
      DebugLogEntry.capture(category: "provider_sync_error", level: "warn", message: "Historical balances retained dates with unavailable FX",
        source: self.class.name, provider_key: @batch.provider_connection&.provider_key, family: @batch.family,
        account_provider: @batch.external_account&.account_provider,
        metadata: { ingestion_batch_id: @batch.id, external_account_id: @batch.external_account_id,
          failed_fx_dates: command[:failed_fx_dates].map(&:iso8601) })
    end
end
