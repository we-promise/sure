require "digest"

# Switch one prepared connection and install its first native Sync atomically.
# This is deliberately an explicit operator command, not a background copy step.
class Provider::AccountData::MigrationCutover
  class Conflict < Provider::AccountData::StaleWriter; end
  class Busy < Provider::AccountData::IncompletePage; end
  FORMAT = "provider-native-cutover/v1".freeze
  MAX_ACCOUNTS = 100
  MAX_ENTRIES = 10_000
  HISTORY_VERIFIERS = {
    "enable_banking" => "Provider::AccountData::EnableBanking::CutoverHistory",
    "akahu" => "Provider::AccountData::Akahu::CutoverHistory",
    "up" => "Provider::AccountData::Up::CutoverHistory",
    "mercury" => "Provider::AccountData::Mercury::CutoverHistory",
    "brex" => "Provider::AccountData::Brex::CutoverHistory"
  }.freeze
  Result = Data.define(:control_id, :connection_id, :sync_id, :replayed)

  def initialize(provider_key:, legacy_item_id:, family:, page_size: 100)
    unless family.is_a?(Family) && family.persisted? && page_size.is_a?(Integer) && (1..500).cover?(page_size)
      raise ArgumentError, "Cutover requires an authorized family and bounded page size"
    end
    @provider_key, @legacy_item_id, @family_id, @page_size = provider_key, legacy_item_id, family.id, page_size
  end

  def call
    unless ApplicationRecord.connection.open_transactions.zero?
      raise ArgumentError, "Cutover must acquire its legacy permit before any database transaction"
    end
    raise Conflict, "Provider has no reviewed cutover history contract" unless HISTORY_VERIFIERS.key?(@provider_key)
    Provider::AccountData::Registry.fetch(@provider_key)
    raise Conflict, "Configure encryption before migration cutover" unless ActiveRecordEncryptionConfig.ready?
    family = Family.find(@family_id)
    @manifest = Provider::AccountData::MigrationManifest.for(@provider_key)
    item = manifest.item_type.constantize.find_by!(id: @legacy_item_id, family_id: @family_id)
    result = Fence.with_exclusive(item) do
      ApplicationRecord.uncached do
        ProviderCredentialClaim.assert_settled_for!(item)
        EnableBankingItem::Lifecycle.assert_copyable!(item)
        @control = ProviderMigrationControl.find_by!(legacy_type: manifest.item_type, legacy_id: item.id, family_id: family.id, provider_key: @provider_key)
        if control.native_owned?
          ApplicationRecord.transaction(requires_new: true) { replay!(item) }
        else
          assert_prepared!
          original_preparation = control.preparation_state.deep_dup
          auxiliary_context = verify_auxiliary_bytes!(family)
          ApplicationRecord.transaction(requires_new: true) do
            lock_owners!(item)
            assert_prepared!
            unless control.preparation_state == original_preparation
              raise Conflict, "Preparation changed during cutover admission"
            end
            assert_legacy_drained!(item)
            raise Conflict, "Restore the legacy connection before cutover" unless item.good?
            lock_financial_inventory!
            prepared = Preparation.new(provider_key: @provider_key, legacy_item_id: item.id, family: family, page_size: @page_size)
              .verify_for_cutover!(auxiliary_context: auxiliary_context)
            unless prepared.awaiting_acceptance? && prepared.run_id == original_preparation.fetch("run_id")
              raise Conflict, "Cutover lost its original preparation"
            end
            history = HISTORY_VERIFIERS.fetch(@provider_key).constantize.new(item: item, connection: connection, family: family).verify!
            activate!(prepared, history: history)
          end
        end
      end
    end
    # Queue failures leave a durable Sync and receipt. Repeating this command
    # requeues that exact pending run instead of creating another writer/run.
    sync = Sync.find_by!(id: result.sync_id, syncable_type: "ProviderConnection", syncable_id: result.connection_id)
    SyncJob.perform_later(sync) if sync.pending? && sync.cancel_requested_at.nil?
    result
  rescue ActiveRecord::RecordNotFound
    capture_failure(Conflict)
    raise Conflict, "Migration ownership is missing or changed", cause: nil
  rescue ActiveRecord::LockWaitTimeout
    raise Busy, "Migration encountered active work; retry cutover after it finishes", cause: nil
  rescue StandardError => error
    capture_failure(error.class)
    raise
  end

  private
    Fence = Provider::AccountData::LegacyWriterFence
    Preparation = Provider::AccountData::MigrationPreparation
    Value = Provider::AccountData::MigrationValue
    attr_reader :control, :connection, :manifest

    def assert_prepared!
      bytes = ProviderMigrationControl.where(id: control.id).pick(Arel.sql("octet_length(preparation_state)"))
      unless bytes && bytes <= Preparation::MAX_STATE_BYTES * 2
        raise Conflict, "Cutover requires bounded completed preparation"
      end
      state = control.preparation_state
      unless state.is_a?(Hash) && Value.dump(state).bytesize <= Preparation::MAX_STATE_BYTES &&
          state["format"] == Preparation::FORMAT && state["phase"] == "awaiting_acceptance" &&
          state["page_size"] == @page_size && state["requires_cutover_reverification"] == true &&
          control.quiescing? && control.writer_epoch.zero? && control.lease_owner.nil? &&
          control.audit_results["native_cutover"].nil? &&
          state.dig("context", "control_id") == control.id && state.dig("context", "connection_id") == control.provider_connection_id &&
          state.dig("context", "family_id") == @family_id && state.dig("context", "legacy_id") == @legacy_item_id
        raise Conflict, "Cutover requires the original disabled quiesced preparation"
      end
    end

    def verify_auxiliary_bytes!(family)
      expected = control.preparation_state.dig("auxiliary_verification", "context")
      unless expected.is_a?(Hash) && expected["limit"].is_a?(Integer) && (1..8).cover?(expected["limit"])
        raise Conflict, "Cutover has no completed auxiliary verification context"
      end
      copier = Provider::AccountData::AuxiliaryCopier.for(control: control)
      cursor, count = nil, 0
      digest = Preparation::EMPTY_DIGEST
      loop do
        page = copier.verify_retained_page(family: family, cursor: cursor, limit: expected.fetch("limit"))
        raise Conflict, "Auxiliary source changed after preparation" unless page.context == expected
        page.rows.each do |row|
          raise Conflict, "Auxiliary verification skipped a chunk" unless row.fetch("index") == count
          count += 1
          digest = Digest::SHA256.hexdigest(digest + "\0" + Value.dump(row))
        end
        if page.complete
          previous = control.preparation_state.fetch("auxiliary_verification")
          unless count == expected.fetch("chunks") && count == previous["verified_chunks"] && digest == previous["digest"]
            raise Conflict, "Auxiliary verification differs from its original complete sweep"
          end
          return page.context
        end
        cursor = page.next_cursor
      end
    end

    def lock_owners!(item)
      control.lock!("FOR UPDATE NOWAIT")
      @connection = ProviderConnection.where(id: control.provider_connection_id, family_id: @family_id, provider_key: @provider_key)
        .lock("FOR UPDATE NOWAIT").first!
      item.lock!("FOR UPDATE NOWAIT")
      unless control.family_id == @family_id && control.provider_key == @provider_key && control.legacy_type == manifest.item_type &&
          control.legacy_id == item.id && item.family_id == @family_id && !item.scheduled_for_deletion? && !connection.scheduled_for_deletion?
        raise Conflict, "Cutover ownership changed or is scheduled for deletion"
      end
      mappings = control.provider_migration_mappings.where(role: "connection").order(:id).limit(2).lock("FOR UPDATE NOWAIT").to_a
      mapping = mappings.first
      unless mappings.one? && mapping.legacy_type == manifest.item_type && mapping.legacy_id == item.id &&
          mapping.provider_connection_id == connection.id && mapping.family_id == @family_id &&
          mapping.external_account_id.nil? && mapping.provider_authorization_id.nil?
        raise Conflict, "Cutover lost its exact connection mapping"
      end
    end

    def assert_legacy_drained!(item)
      if item.syncs.incomplete.exists?
        raise Conflict, "Finish or resolve queued legacy syncs before cutover"
      end
    end

    # Parent row locks exclude new child inserts through the retained FKs; row
    # locks pin existing values throughout the entire final proof sweep. The
    # pilot rejects larger inventories instead of silently verifying a prefix.
    def lock_financial_inventory!
      external_ids = connection.external_accounts.order(:id).limit(MAX_ACCOUNTS + 1).pluck(:id)
      raise Conflict, "Cutover account inventory exceeds the reviewed transaction bound" if external_ids.size > MAX_ACCOUNTS
      account_ids = AccountProvider.where(external_account_id: external_ids).distinct.order(:account_id).pluck(:account_id)
      accounts = Account.where(id: account_ids, family_id: @family_id).order(:id).lock("FOR UPDATE NOWAIT").to_a
      raise Conflict, "Cutover lost a financial account" unless accounts.map(&:id).sort == account_ids.sort
      ExternalAccount.where(id: external_ids).order(:id).select(:id).lock("FOR UPDATE NOWAIT").to_a
      AccountProvider.where(account_id: account_ids).order(:id).select(:id).lock("FOR UPDATE NOWAIT").to_a
      Account::SourcePolicy.active.where(account_id: account_ids).order(:id).select(:id).lock("FOR UPDATE NOWAIT").to_a
      entries = Entry.where(account_id: account_ids).order(:id).limit(MAX_ENTRIES + 1)
        .select(:id, :entryable_type, :entryable_id).lock("FOR UPDATE NOWAIT").to_a
      raise Conflict, "Cutover financial inventory exceeds the reviewed transaction bound" if entries.size > MAX_ENTRIES
      { "Transaction" => Transaction, "Trade" => Trade, "Valuation" => Valuation }.each do |type, model|
        ids = entries.select { |entry| entry.entryable_type == type }.map(&:entryable_id)
        locked = model.where(id: ids).order(:id).select(:id).lock("FOR UPDATE NOWAIT").to_a
        raise Conflict, "Cutover financial entry lost its value record" unless locked.map(&:id).sort == ids.uniq.sort
      end
      control.provider_migration_mappings.where(role: "external_account").order(:id).each do |mapping|
        next unless AccountProvider.where(external_account_id: mapping.external_account_id).exists?
        Provider::AccountData::MigrationSourceSelection.ensure!(mapping: mapping, family: connection.family)
      end
    end

    def activate!(prepared, history:)
      # Child verifiers reload their own objects; retain only freshly locked
      # ownership here, with no lease, native batches or Sync accepted beforehand.
      control.reload
      connection.reload
      unless control.quiescing? && control.writer_epoch.zero? && connection.disabled? && connection.writer_epoch.zero? &&
          connection.lease_owner.nil? && connection.syncs.none?
        raise Conflict, "Native ownership changed during final verification"
      end
      # Keep first-read dates account-scoped. A connection-wide Sync override
      # would widen siblings past their own explicitly configured start dates.
      # Install only after the copy comparison, which checks original metadata.
      starts = serialize_history_starts!(history.account_starts)
      starts.each do |external_id, start|
        external = connection.external_accounts.find_by!(id: external_id, family_id: @family_id)
        external.update!(metadata: external.metadata.merge("#{@provider_key}_initial_history_start" => start))
      end
      connection.update!(status: "good", writer_epoch: 1)
      control.update!(state: "active", writer_epoch: 1)
      sync = connection.syncs.create!(status: "pending")
      receipt = { "format" => FORMAT, "preparation_run_id" => prepared.run_id,
        "copy_run_id" => control.high_water_mark.fetch("copy_run_id"), "connection_id" => connection.id,
        "sync_id" => sync.id, "writer_epoch" => 1, "account_starts" => starts,
        "activated_at" => Time.current.utc.iso8601(6) }
      control.update!(audit_results: control.audit_results.merge("native_cutover" => receipt))
      Result.new(control_id: control.id, connection_id: connection.id, sync_id: sync.id, replayed: false)
    end

    def serialize_history_starts!(account_starts)
      expected = connection.external_accounts.order(:id).pluck(:id)
      unless account_starts.is_a?(Hash) && account_starts.keys.all? { |id| id.is_a?(String) } && account_starts.keys.sort == expected
        raise Conflict, "Cutover history must cover the exact external account inventory"
      end
      account_starts.transform_values do |start|
        # A reviewed nil is an explicit full-accessible-history request, never a
        # missing result. Keep the account key in both metadata and the receipt.
        if start.nil? && %w[akahu enable_banking].include?(@provider_key)
          nil
        elsif start.instance_of?(Date)
          start.iso8601
        else
          raise Conflict, "Cutover history has an invalid first-read boundary"
        end
      end
    end

    def replay!(item)
      lock_owners!(item)
      receipt = control.audit_results["native_cutover"]
      unless control.native_owned? && connection.good? && receipt.is_a?(Hash) && receipt["format"] == FORMAT &&
          receipt["connection_id"] == connection.id && receipt["writer_epoch"] == 1 &&
          control.writer_epoch == 1 && connection.writer_epoch >= 1 &&
          receipt["preparation_run_id"] == control.preparation_state["run_id"] &&
          receipt["copy_run_id"] == control.high_water_mark["copy_run_id"]
        raise Conflict, "Native ownership has no matching cutover receipt"
      end
      sync = connection.syncs.find(receipt.fetch("sync_id"))
      Result.new(control_id: control.id, connection_id: connection.id, sync_id: sync.id, replayed: true)
    end

    def capture_failure(error_class)
      DebugLogEntry.capture(category: "provider_migration_error", level: "error", message: "Provider cutover requires retry or review",
        source: self.class.name, provider_key: @provider_key, family_id: @family_id,
        metadata: { migration_control_id: control&.id, legacy_item_id: @legacy_item_id, error_class: error_class.name })
    rescue StandardError
      nil
    end
end
