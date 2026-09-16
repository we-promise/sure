require "set"

# Reconcile the retained cache with authenticated financial identities before
# handover. This never imports a cache or treats it as a complete pending feed.
class Provider::AccountData::Akahu::CutoverHistory
  class Conflict < Provider::AccountData::StaleWriter; end

  MAX_ACCOUNTS = 100
  MAX_RECORDS = 10_000
  MAX_BYTES = 32 * 1024 * 1024
  MAX_IDENTITY_BYTES = 1024 * 1024
  Result = Data.define(:account_starts)

  def initialize(item:, connection:, family:)
    unless item.is_a?(AkahuItem) && item.persisted? && connection.is_a?(ProviderConnection) && connection.persisted? &&
        family.is_a?(Family) && family.persisted?
      raise ArgumentError, "Akahu history verification requires persisted ownership"
    end
    @item_id, @connection_id, @family_id = item.id, connection.id, family.id
  end

  def verify!
    raise ArgumentError, "Akahu history verification requires the final cutover transaction" if ApplicationRecord.connection.open_transactions.zero?

    ApplicationRecord.uncached do
      load_context!
      @account_starts = {}
      @record_count, @archive_bytes = 0, 0
      @proof = Provider::AccountData::MigrationHistoryProof.new(connection: connection, control: control,
        family_id: @family_id, source: "akahu", max_bytes: MAX_BYTES, max_identity_bytes: MAX_IDENTITY_BYTES)
      verify_accounts!
      Result.new(account_starts: Provider::AccountData::MigrationManifest.copy_value(@account_starts)).freeze
    end
  rescue ActiveRecord::RecordNotFound, ActiveRecord::SoleRecordExceeded, KeyError, TypeError,
      Provider::AccountData::InvalidResponse, Ingestion::LegacyIdentityEvidence::InvalidEvidence,
      Provider::AccountData::MigrationHistoryProof::Conflict
    raise Conflict, "Akahu cached history requires exact retained financial provenance", cause: nil
  end

  private
    attr_reader :item, :connection, :control, :reader

    def load_context!
      @item = AkahuItem.find_by!(id: @item_id, family_id: @family_id)
      Provider::AccountData::LegacyWriterFence.assert_exclusive!(item)
      @control = ProviderMigrationControl.find_by!(legacy_type: "AkahuItem", legacy_id: item.id,
        family_id: @family_id, provider_key: "akahu", provider_connection_id: @connection_id)
      @connection = ProviderConnection.find_by!(id: @connection_id, family_id: @family_id, provider_key: "akahu")
      unless control.quiescing? && control.writer_epoch.zero? && control.lease_owner.nil? &&
          connection.disabled? && connection.writer_epoch.zero? && connection.lease_owner.nil? &&
          !item.scheduled_for_deletion? && !connection.scheduled_for_deletion?
        raise Conflict, "Akahu history requires the original disabled quiesced ownership"
      end
      @reader = Provider::AccountData::RetainedRow.new(connection: connection, provider_key: "akahu")
      original = reader.item
      unless original && original.attributes["sync_start_date"] == item.sync_start_date && connection.sync_start_date == item.sync_start_date
        raise Conflict, "Akahu history configuration changed after copying"
      end
      @normalizer = Provider::AccountData::Akahu.new(client: nil, timezone: Family.find(@family_id).timezone)
    end

    def verify_accounts!
      ids = AkahuAccount.where(akahu_item_id: item.id).order(:id).limit(MAX_ACCOUNTS + 1).pluck(:id)
      raise Conflict, "Akahu history exceeds its account bound" if ids.size > MAX_ACCOUNTS
      mappings = control.provider_migration_mappings.where(role: "external_account").order(:id).limit(MAX_ACCOUNTS + 1).to_a
      unless mappings.size == ids.size && mappings.map(&:legacy_id).sort == ids &&
          mappings.all? { |mapping| mapping.legacy_type == "AkahuAccount" && mapping.family_id == @family_id }
        raise Conflict, "Akahu history account inventory changed"
      end
      if connection.external_accounts.where.not(id: mappings.map(&:external_account_id)).exists?
        raise Conflict, "Akahu history contains an uncopied external account"
      end

      # Bound stored ciphertext before decrypting a cache, then repeat the
      # predicate on the materializing query. Retained plaintext is bounded too.
      size_sql = "COALESCE(octet_length(raw_transactions_payload::text), 0)"
      raise Conflict, "Akahu history exceeds its stored cache bound" if AkahuAccount.where(id: ids).sum(Arel.sql(size_sql)) > MAX_BYTES
      Ingestion::LegacyIdentityEvidence.with_validation_cache do
        mappings.each { |mapping| verify_account!(mapping, size_sql) }
      end
    end

    def verify_account!(mapping, size_sql)
      external = connection.external_accounts.find_by!(id: mapping.external_account_id, family_id: @family_id, provider_key: "akahu")
      links = AccountProvider.where("external_account_id = :external OR (provider_type = 'AkahuAccount' AND provider_id = :source)",
        external: external.id, source: mapping.legacy_id).limit(2).to_a
      raise Conflict, "Akahu history has ambiguous account ownership" if links.size > 1
      link = links.first
      account = link && Account.where(id: link.account_id, family_id: @family_id).lock("FOR UPDATE NOWAIT").first!
      if link && (link.provider_type != "AkahuAccount" || link.provider_id != mapping.legacy_id ||
          link.external_account_id != external.id || link.family_id != @family_id || link.provider_key != "akahu" ||
          !%w[active draft disabled].include?(account.status))
        raise Conflict, "Akahu history account binding changed"
      end
      source = AkahuAccount.where(id: mapping.legacy_id, akahu_item_id: item.id).where("#{size_sql} <= ?", MAX_BYTES)
        .select(:id, :akahu_item_id, :account_id, :currency, :sync_start_date, :raw_transactions_payload).lock("FOR UPDATE NOWAIT").first!
      retained = reader.account(external)
      raise Conflict, "Akahu history has no retained account" unless retained
      @archive_bytes += retained.byte_size
      raise Conflict, "Akahu history exceeds its retained archive bound" if @archive_bytes > MAX_BYTES
      Provider::AccountData::MigrationCopier.verify_account_binding!(archive: retained.archive, link: link, financial: account)
      raw = source.raw_transactions_payload
      unless retained.attributes["raw_transactions_payload"] == raw && retained.attributes["sync_start_date"] == source.sync_start_date &&
          source.account_id == external.external_id && source.currency == external.currency && external.sync_start_date == source.sync_start_date
        raise Conflict, "Akahu history differs from its verified original cache"
      end
      raw = [] if raw.nil?
      raise Conflict, "Akahu transaction cache is malformed" unless raw.is_a?(Array)
      @record_count += raw.size
      raise Conflict, "Akahu history exceeds its transaction bound" if @record_count > MAX_RECORDS
      raise Conflict, "Link or explicitly reconcile cached Akahu history before cutover" if account.nil? && raw.any?

      seen = Set.new
      raw.each do |data|
        raise Conflict, "Akahu transaction cache contains an unknown row" unless data.is_a?(Hash)
        record = @normalizer.normalize_legacy_transaction(data, account: { external_id: source.account_id, currency: source.currency })
        raise Conflict, "Akahu transaction cache contains repeated identities" unless seen.add?(record[:external_id])
        @proof.verify_transaction!(record: record, mapping: mapping, external: external, link: link, account: account) do |row, identity|
          if record[:metadata][:identity_policy]
            Provider::AccountData::Akahu::PendingIdentity.new(external_account: external, account: account)
              .verify_bootstrap!(record: record, row: row, identity: identity)
          end
          cached_version_disposed?(record, row, identity)
        end
      end

      # Native initial acquisition deliberately rereads the full accessible range
      # unless the user chose a floor. A stale/partial legacy pending fetch or
      # item-wide success timestamp must not narrow that first account request.
      @account_starts[external.id] = source.sync_start_date || item.sync_start_date
    rescue Provider::AccountData::Akahu::PendingIdentity::Conflict
      raise Conflict, "Akahu pending cache requires exact original occurrence provenance", cause: nil
    rescue Provider::AccountData::MigrationCopier::Conflict
      raise Conflict, "Akahu history copy-time account ownership changed", cause: nil
    end

    def cached_version_disposed?(record, row, identity)
      return record[:pending] if identity["role"] == "retired_alias"
      return false unless identity["role"] == "current" && identity["pending"] == record[:pending]

      # Preserve subsequent user edits; the authenticated bootstrap snapshot is
      # the evidence that this cached version was already financially processed.
      snapshot = Provider::AccountData::MigrationValue.decode(row.fetch("financial_snapshot"))
      original, transaction = snapshot.values_at("entry", "entryable")
      metadata = record[:metadata].with_indifferent_access
      %w[amount currency date name].all? { |key| original[key] == record[key.to_sym] } &&
        original["notes"] == metadata[:notes] && transaction.fetch("extra").is_a?(Hash) &&
        transaction.fetch("extra")["akahu"] == metadata.fetch(:extra).fetch("akahu")
    end
end
