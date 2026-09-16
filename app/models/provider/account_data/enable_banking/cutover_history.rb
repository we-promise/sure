require "set"

# Cached observations must have an authenticated financial disposition before
# ownership changes. A copied session or successful Sync is not history coverage.
class Provider::AccountData::EnableBanking::CutoverHistory
  class Conflict < Provider::AccountData::StaleWriter; end

  MAX_ACCOUNTS = 100
  MAX_RECORDS = 10_000
  MAX_BYTES = 32 * 1024 * 1024
  MAX_IDENTITY_BYTES = 1024 * 1024
  Result = Data.define(:account_starts)

  def initialize(item:, connection:, family:)
    unless item.is_a?(EnableBankingItem) && item.persisted? && connection.is_a?(ProviderConnection) && connection.persisted? &&
        family.is_a?(Family) && family.persisted?
      raise ArgumentError, "Enable Banking history requires persisted ownership"
    end
    @item_id, @connection_id, @family_id = item.id, connection.id, family.id
  end

  def verify!
    raise ArgumentError, "Enable Banking history requires the final cutover transaction" unless ApplicationRecord.connection.transaction_open?

    ApplicationRecord.uncached do
      load_context!
      @account_starts, @aliases = {}, {}
      @record_count = 0
      @proof = Provider::AccountData::MigrationHistoryProof.new(connection: connection, control: control,
        family_id: @family_id, source: "enable_banking", max_bytes: MAX_BYTES, max_identity_bytes: MAX_IDENTITY_BYTES)
      verify_accounts!
      Result.new(account_starts: Provider::AccountData::MigrationManifest.copy_value(@account_starts)).freeze
    end
  rescue ActiveRecord::RecordNotFound, ActiveRecord::SoleRecordExceeded, KeyError, TypeError,
      Provider::AccountData::InvalidResponse, Provider::AccountData::MigrationHistoryProof::Conflict,
      Ingestion::LegacyIdentityEvidence::InvalidEvidence, Provider::AccountData::MigrationCopier::Conflict
    raise Conflict, "Enable Banking cached history requires exact retained financial provenance", cause: nil
  end

  private
    attr_reader :item, :connection, :control, :reader, :authorization

    def load_context!
      @item = EnableBankingItem.find_by!(id: @item_id, family_id: @family_id)
      Provider::AccountData::LegacyWriterFence.assert_exclusive!(item)
      EnableBankingItem::Lifecycle.assert_copyable!(item)
      @control = ProviderMigrationControl.find_by!(legacy_type: "EnableBankingItem", legacy_id: item.id,
        family_id: @family_id, provider_key: "enable_banking", provider_connection_id: @connection_id)
      @connection = ProviderConnection.find_by!(id: @connection_id, family_id: @family_id, provider_key: "enable_banking")
      unless control.quiescing? && control.writer_epoch.zero? && control.lease_owner.nil? &&
          connection.disabled? && connection.writer_epoch.zero? && connection.lease_owner.nil? &&
          !item.scheduled_for_deletion? && !connection.scheduled_for_deletion? && item.good? &&
          item.authorization_id.blank? && item.session_valid?
        raise Conflict, "Enable Banking history requires its original usable quiesced consent"
      end
      @reader = Provider::AccountData::RetainedRow.new(connection: connection, provider_key: "enable_banking")
      original = reader.item
      unless original && original.attributes == item.attributes && connection.sync_start_date == item.sync_start_date
        raise Conflict, "Enable Banking configuration changed after copying"
      end
      @archive_bytes = original.byte_size
      verify_authorization!
      @normalizer = Provider::AccountData::EnableBanking.new(client: nil, timezone: Family.find(@family_id).timezone,
        authorizations: [], external_accounts: [], known_merchant_names: merchant_names, observed_at: Time.current, include_pending: true)
    end

    def verify_authorization!
      mapping = control.provider_migration_mappings.where(role: "authorization").sole
      unless mapping.legacy_type == "EnableBankingItem" && mapping.legacy_id == item.id && mapping.family_id == @family_id &&
          mapping.provider_connection_id == connection.id && mapping.external_account_id.nil? && mapping.verified_at &&
          mapping.source_checksum == control.provider_migration_mappings.where(role: "connection").sole.source_checksum
        raise Conflict, "Enable Banking history lost its original consent mapping"
      end
      @authorization = connection.provider_authorizations.lock("FOR UPDATE NOWAIT").sole
      projection = Provider::AccountData::MigrationManifest.for("enable_banking").extract_item(item)
      grant_fields = Provider::AccountData::MigrationManifest::AUTHORIZATION_FIELDS
      unless authorization.id == mapping.provider_authorization_id && authorization.family_id == @family_id && authorization.usable? &&
          authorization.external_id == item.authorization_id && authorization.expires_at == item.session_expires_at &&
          authorization.credentials == projection.credentials.slice(*grant_fields).merge(projection.sensitive_data.slice(*grant_fields)) &&
          authorization.metadata == { "legacy_type" => "EnableBankingItem", "legacy_id" => item.id,
            "grant_settings" => projection.settings.slice(*grant_fields) } &&
          authorization.institution_metadata == projection.metadata.slice("aspsp_name", "institution_id", "institution_name").merge(projection.identity.slice("aspsp_id")) &&
          connection.credentials == projection.credentials.except(*grant_fields) &&
          connection.settings == projection.settings.except(*grant_fields)
        raise Conflict, "Enable Banking copied consent or application changed"
      end
    end

    def verify_accounts!
      ids = item.enable_banking_accounts.order(:id).limit(MAX_ACCOUNTS + 1).pluck(:id)
      mappings = control.provider_migration_mappings.where(role: "external_account").order(:id).limit(MAX_ACCOUNTS + 1).to_a
      unless ids.size <= MAX_ACCOUNTS && mappings.size == ids.size && mappings.map(&:legacy_id).sort == ids &&
          mappings.all? { |mapping| mapping.legacy_type == "EnableBankingAccount" && mapping.family_id == @family_id } &&
          !connection.external_accounts.where.not(id: mappings.map(&:external_account_id)).exists?
        raise Conflict, "Enable Banking history account inventory changed or exceeds its bound"
      end
      memberships = ProviderAuthorizationAccount.where(provider_connection_id: connection.id).order(:id).limit(MAX_ACCOUNTS + 1).lock("FOR UPDATE NOWAIT").to_a
      unless memberships.size == ids.size && memberships.map(&:external_account_id).sort == mappings.map(&:external_account_id).sort &&
          memberships.all? { |membership| membership.family_id == @family_id && membership.provider_authorization_id == authorization.id && membership.active? }
        raise Conflict, "Enable Banking history consent membership changed"
      end
      size_sql = "COALESCE(octet_length(raw_transactions_payload::text), 0) + COALESCE(octet_length(raw_payload::text), 0)"
      raise Conflict, "Enable Banking history exceeds its stored cache bound" if item.enable_banking_accounts.sum(Arel.sql(size_sql)) > MAX_BYTES
      Ingestion::LegacyIdentityEvidence.with_validation_cache do
        mappings.each { |mapping| verify_account!(mapping, size_sql) }
      end
    end

    def verify_account!(mapping, size_sql)
      external = connection.external_accounts.find_by!(id: mapping.external_account_id, family_id: @family_id, provider_key: "enable_banking")
      links = AccountProvider.where("external_account_id = :external OR (provider_type = 'EnableBankingAccount' AND provider_id = :source)",
        external: external.id, source: mapping.legacy_id).limit(2).to_a
      raise Conflict, "Enable Banking history has ambiguous financial ownership" if links.size > 1
      link = links.first
      account = link && Account.where(id: link.account_id, family_id: @family_id).lock("FOR UPDATE NOWAIT").first!
      if link && (link.provider_type != "EnableBankingAccount" || link.provider_id != mapping.legacy_id ||
          link.external_account_id != external.id || link.family_id != @family_id || link.provider_key != "enable_banking" ||
          !%w[active draft disabled].include?(account.status))
        raise Conflict, "Enable Banking history financial binding changed"
      end
      source = item.enable_banking_accounts.where(id: mapping.legacy_id).where("#{size_sql} <= ?", MAX_BYTES).lock("FOR UPDATE NOWAIT").first!
      retained = reader.account(external)
      raise Conflict, "Enable Banking history has no retained account" unless retained
      @archive_bytes += retained.byte_size
      raise Conflict, "Enable Banking history exceeds its retained archive bound" if @archive_bytes > MAX_BYTES
      Provider::AccountData::MigrationCopier.verify_account_binding!(archive: retained.archive, link: link, financial: account)
      projection = Provider::AccountData::MigrationManifest.for("enable_banking").extract_account(source)
      copied_values = Provider::AccountData::MigrationCopier::TARGET_ACCOUNT_COLUMNS.to_h { |column| [ column, projection.attributes[column] ] }
      unless retained.attributes == source.attributes && source.uid == external.external_id && source.currency == external.currency &&
          external.sync_start_date.nil? && external.identity_namespace == projection.identity_namespace &&
          external.attributes.slice(*copied_values.keys) == copied_values && external.account_type == source.account_type &&
          external.metadata["source_details"] == Provider::AccountData::MigrationValue.encode(projection.buckets.slice(:identity, :attributes, :settings, :metadata)) &&
          external.sensitive_details == projection.sensitive_data
        raise Conflict, "Enable Banking history differs from its original source and route"
      end
      [ source.uid, source.account_id, *Array(source.identification_hashes) ].compact.uniq.each do |identity|
        if !identity.is_a?(String) || identity.blank? || (@aliases.key?(identity) && @aliases[identity] != source.id)
          raise Conflict, "Enable Banking copied accounts have ambiguous routing aliases"
        end
        @aliases[identity] = source.id
      end
      raw = source.raw_transactions_payload
      raw = [] if raw.nil?
      raise Conflict, "Enable Banking transaction cache is malformed" unless raw.is_a?(Array)
      @record_count += raw.size
      raise Conflict, "Enable Banking history exceeds its transaction bound" if @record_count > MAX_RECORDS
      raise Conflict, "Link or reconcile cached Enable Banking history before cutover" if account.nil? && raw.any?
      seen = Set.new
      raw.each do |data|
        raise Conflict, "Enable Banking cache contains an unknown row" unless data.is_a?(Hash)
        record = @normalizer.normalize_legacy_transaction(data, account: { external_id: source.uid, currency: account.currency })
        raise Conflict, "Enable Banking cache repeats an identity" unless seen.add?(record[:external_id])
        @proof.verify_transaction!(record: record, mapping: mapping, external: external, link: link, account: account) do |row, identity|
          cached_version_disposed?(record, row, identity)
        end
      end
      @account_starts[external.id] = item.sync_start_date
    end

    def cached_version_disposed?(record, row, identity)
      return record[:pending] if identity["role"] == "retired_alias"
      return false unless identity["role"] == "current" && identity["pending"] == record[:pending]

      snapshot = Provider::AccountData::MigrationValue.decode(row.fetch("financial_snapshot"))
      original, transaction = snapshot.values_at("entry", "entryable")
      metadata = record[:metadata].with_indifferent_access
      extra = transaction.fetch("extra")
      return false unless extra.is_a?(Hash)
      provider_extra = extra.fetch("enable_banking", {})
      return false unless provider_extra.is_a?(Hash)
      # Legacy booked rows omit pending:false; this omission is not a changed
      # financial value. status:PDNG without legacy _pending still refuses above.
      provider_extra = provider_extra.merge("pending" => provider_extra["pending"] == true)
      %w[amount currency date name].all? { |key| original[key] == record[key.to_sym] } &&
        original["notes"] == metadata[:notes] && provider_extra == metadata.fetch(:extra).fetch("enable_banking")
    end

    def merchant_names
      family = Family.find(@family_id)
      assigned = Transaction.joins(:entry).where(entries: { account_id: family.accounts.select(:id) }).where.not(merchant_id: nil).select(:merchant_id)
      scope = Merchant.where(id: assigned).or(Merchant.where(id: family.merchants.select(:id)))
      ids = scope.order(:id).limit(MAX_RECORDS + 1).pluck(:id)
      if ids.size > MAX_RECORDS || scope.where("octet_length(name) > 1024").exists?
        raise Conflict, "Enable Banking merchant context exceeds its bound"
      end
      names = scope.where(id: ids).where("octet_length(name) <= 1024").order(:id).pluck(:name)
      raise Conflict, "Enable Banking merchant context changed" unless names.size == ids.size && names.all? { |name| name.is_a?(String) }
      names.uniq
    end
end
