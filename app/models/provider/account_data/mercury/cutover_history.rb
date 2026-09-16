require "set"
require "time"

# Per-account first-read bounds, not proof of coverage or a cache importer.
# The cutover caller must first finish its fresh copy and financial identity
# sweeps, retaining the exclusive item permit and financial row locks throughout.
class Provider::AccountData::Mercury::CutoverHistory
  class Conflict < Provider::AccountData::StaleWriter; end

  MAX_ACCOUNTS = 100
  MAX_RECORDS = 10_000
  MAX_BYTES = 32 * 1024 * 1024
  MAX_IDENTITY_BYTES = 1024 * 1024
  Result = Data.define(:account_starts)

  def initialize(item:, connection:, family:)
    unless item.is_a?(MercuryItem) && item.persisted? && connection.is_a?(ProviderConnection) && connection.persisted? &&
        family.is_a?(Family) && family.persisted?
      raise ArgumentError, "Mercury history verification requires persisted ownership"
    end
    @item_id, @connection_id, @family_id = item.id, connection.id, family.id
  end

  def verify!
    raise ArgumentError, "Mercury history verification requires the final cutover transaction" if ApplicationRecord.connection.open_transactions.zero?

    ApplicationRecord.uncached do
      load_context!
      @default_start = Time.current.getutc.to_date - 90.days
      @completed_at = Sync.where(syncable_type: "MercuryItem", syncable_id: item.id, status: "completed")
        .order(created_at: :desc, id: :desc).pick(:completed_at)
      @account_starts = {}
      @record_count, @archive_bytes = 0, 0
      @history_proof = Provider::AccountData::MigrationHistoryProof.new(connection: connection, control: control,
        family_id: @family_id, source: "mercury", max_bytes: MAX_BYTES, max_identity_bytes: MAX_IDENTITY_BYTES)
      verify_accounts!
      Result.new(account_starts: Provider::AccountData::MigrationManifest.copy_value(@account_starts)).freeze
    end
  rescue ActiveRecord::RecordNotFound, ActiveRecord::SoleRecordExceeded, KeyError, TypeError,
      Provider::AccountData::InvalidResponse, Ingestion::LegacyIdentityEvidence::InvalidEvidence,
      Provider::AccountData::MigrationHistoryProof::Conflict
    raise Conflict, "Mercury cached history requires exact retained financial provenance", cause: nil
  end

  private
    attr_reader :item, :connection, :control, :reader

    def load_context!
      @item = MercuryItem.find_by!(id: @item_id, family_id: @family_id)
      Provider::AccountData::LegacyWriterFence.assert_exclusive!(item)
      @control = ProviderMigrationControl.find_by!(legacy_type: "MercuryItem", legacy_id: item.id,
        family_id: @family_id, provider_key: "mercury", provider_connection_id: @connection_id)
      @connection = ProviderConnection.find_by!(id: @connection_id, family_id: @family_id, provider_key: "mercury")
      unless control.quiescing? && control.writer_epoch.zero? && control.lease_owner.nil? &&
          connection.disabled? && connection.writer_epoch.zero? && connection.lease_owner.nil? &&
          !item.scheduled_for_deletion? && !connection.scheduled_for_deletion?
        raise Conflict, "Mercury history requires the original disabled quiesced ownership"
      end
      @reader = Provider::AccountData::RetainedRow.new(connection: connection, provider_key: "mercury")
      original = reader.item
      unless original && original.attributes["sync_start_date"] == item.sync_start_date && connection.sync_start_date == item.sync_start_date&.to_date
        raise Conflict, "Mercury history configuration changed after copying"
      end
      @normalizer = Provider::AccountData::Mercury.new(client: nil, timezone: Family.find(@family_id).timezone)
    end

    def verify_accounts!
      ids = MercuryAccount.where(mercury_item_id: item.id).order(:id).limit(MAX_ACCOUNTS + 1).pluck(:id)
      raise Conflict, "Mercury history exceeds its account bound" if ids.size > MAX_ACCOUNTS
      mappings = control.provider_migration_mappings.where(role: "external_account").order(:id).limit(MAX_ACCOUNTS + 1).to_a
      unless mappings.size == ids.size && mappings.map(&:legacy_id).sort == ids &&
          mappings.all? { |mapping| mapping.legacy_type == "MercuryAccount" && mapping.family_id == @family_id }
        raise Conflict, "Mercury history account inventory changed"
      end
      if connection.external_accounts.where.not(id: mappings.map(&:external_account_id)).exists?
        raise Conflict, "Mercury history contains an uncopied external account"
      end

      # Ciphertext preflight precedes loading any raw cache; repeat the predicate
      # on the materializing SELECT so concurrent growth cannot evade this cap.
      size_sql = "COALESCE(octet_length(raw_transactions_payload::text), 0)"
      stored_bytes = MercuryAccount.where(id: ids).sum(Arel.sql(size_sql))
      raise Conflict, "Mercury history exceeds its stored cache bound" if stored_bytes > MAX_BYTES
      Ingestion::LegacyIdentityEvidence.with_validation_cache do
        mappings.each do |mapping|
          verify_account!(mapping, size_sql)
        end
      end
    end

    def verify_account!(mapping, size_sql)
      external = connection.external_accounts.find_by!(id: mapping.external_account_id, family_id: @family_id, provider_key: "mercury")
      links = AccountProvider.where("external_account_id = :external OR (provider_type = 'MercuryAccount' AND provider_id = :source)",
        external: external.id, source: mapping.legacy_id).limit(2).to_a
      raise Conflict, "Mercury history has ambiguous account ownership" if links.size > 1
      link = links.first
      account = link && Account.where(id: link.account_id, family_id: @family_id).lock("FOR UPDATE NOWAIT").first!
      if link && (link.provider_type != "MercuryAccount" || link.provider_id != mapping.legacy_id ||
          link.external_account_id != external.id || link.family_id != @family_id || link.provider_key != "mercury" ||
          !%w[active draft disabled].include?(account.status))
        raise Conflict, "Mercury history account binding changed"
      end
      source = MercuryAccount.where(id: mapping.legacy_id, mercury_item_id: item.id).where("#{size_sql} <= ?", MAX_BYTES)
        .select(:id, :mercury_item_id, :account_id, :currency, :created_at, :raw_transactions_payload).lock("FOR UPDATE NOWAIT").first!
      retained = reader.account(external)
      raise Conflict, "Mercury history has no retained account" unless retained
      @archive_bytes += retained.byte_size
      raise Conflict, "Mercury history exceeds its retained archive bound" if @archive_bytes > MAX_BYTES
      Provider::AccountData::MigrationCopier.verify_account_binding!(archive: retained.archive, link: link, financial: account)
      raw = source.raw_transactions_payload
      unless retained.attributes["raw_transactions_payload"] == raw && retained.attributes["created_at"] == source.created_at &&
          source.account_id == external.external_id && source.currency == "USD" && external.currency == "USD" && external.sync_start_date.nil?
        raise Conflict, "Mercury history differs from its verified original cache"
      end
      raw = [] if raw.nil?
      raise Conflict, "Mercury transaction cache is malformed" unless raw.is_a?(Array)
      @record_count += raw.size
      raise Conflict, "Mercury history exceeds its transaction bound" if @record_count > MAX_RECORDS
      # The old importer ignored item.sync_start_date. Native cutover deliberately
      # honors that copied user setting as a floor. Without it, preserve Mercury's
      # account-creation bound for an empty cache and item-success overlap only
      # for a nonempty cache. A sibling's older history never widens this account.
      configured_start = item.sync_start_date&.to_date
      baseline = if raw.any?
        @completed_at ? @completed_at.getutc.to_date - 7.days : @default_start
      else
        [ source.created_at.getutc.to_date - 7.days, @default_start ].max
      end
      start = configured_start || baseline

      seen = Set.new
      raw.each do |data|
        raise Conflict, "Mercury transaction cache contains an unknown row" unless data.is_a?(Hash)
        data = data.with_indifferent_access
        raise Conflict, "Mercury transaction cache has no explicit status" unless data[:status].is_a?(String) && data[:status].present?
        failed = data[:status] == "failed"
        # Both importers skip failures. Validate their original fields without
        # changing the archived row or pretending that it has a financial posting.
        record = @normalizer.normalize_legacy_transaction(failed ? data.merge(status: "sent") : data,
          account: { external_id: source.account_id, currency: source.currency })
        raise Conflict, "Mercury transaction cache contains repeated identities" unless seen.add?(record[:external_id])
        dates = data.values_at(:createdAt, :postedAt).compact
        raise Conflict, "Mercury transaction cache has no original date" if dates.empty?
        cached_start = dates.map { |date| lower_date!(date) }.min
        start = [ start, cached_start ].min unless configured_start
        if failed
          verify_failed!(record, external, account)
        else
          raise Conflict, "Link or explicitly reconcile cached Mercury history before cutover" unless account
          verify_identity!(record, mapping, external, link, account)
        end
      end
      @account_starts[external.id] = start
    rescue Provider::AccountData::MigrationCopier::Conflict
      raise Conflict, "Mercury history copy-time account ownership changed", cause: nil
    end

    def verify_failed!(record, external, account)
      id = record[:external_id]
      if SourceRecord.where(external_account_id: external.id, external_id: id).exists? ||
          (account && (account.entries.where(external_id: id).exists? ||
            account.entries.where(source: "mercury", entryable_type: "Transaction")
              .joins("INNER JOIN transactions ON transactions.id = entries.entryable_id")
              .where("transactions.extra -> 'auto_claimed_pending_ids' ? :id", id: id).exists?))
        raise Conflict, "Failed Mercury history has an unresolved financial identity"
      end
    end

    def verify_identity!(record, mapping, external, link, account)
      @history_proof.verify_transaction!(record: record, mapping: mapping, external: external, link: link, account: account) do |row, identity|
        cached_version_disposed?(record, row, identity)
      end
    end

    def cached_version_disposed?(record, row, identity)
      # The signed alias explicitly suppresses that old pending identity. A
      # settled observation under an alias instead needs a reviewed transition.
      return record[:pending] if identity["role"] == "retired_alias"
      return false unless identity["role"] == "current" && identity["pending"] == record[:pending]

      # Compare the original captured financial values, never current user edits.
      # Overrides predating bootstrap cannot be distinguished from a failed cache
      # update and conservatively require review rather than an inferred import.
      snapshot = Provider::AccountData::MigrationValue.decode(row.fetch("financial_snapshot"))
      original, transaction = snapshot.values_at("entry", "entryable")
      metadata = record[:metadata].with_indifferent_access
      %w[amount currency date name].all? { |key| original[key] == record[key.to_sym] } &&
        original["notes"] == metadata[:notes] &&
        transaction.fetch("extra").is_a?(Hash) && transaction.fetch("extra")["mercury"] == metadata.fetch(:extra).fetch("mercury")
    end

    def lower_date!(value)
      return value if value.instance_of?(Date)
      return value.to_time.getutc.to_date if value.is_a?(Time) || value.is_a?(DateTime)
      raise ArgumentError unless value.is_a?(String) && value.present?
      return Date.iso8601(value) unless value.match?(/[T:]/)
      raise ArgumentError unless value.match?(/(?:Z|[+-]\d{2}:\d{2})\z/)
      Time.iso8601(value).getutc.to_date
    rescue ArgumentError, RangeError
      raise Conflict, "Mercury cached history has an invalid original date", cause: nil
    end
end
