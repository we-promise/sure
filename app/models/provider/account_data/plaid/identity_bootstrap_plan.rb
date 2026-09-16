require "digest"

# Read-only, bounded preparation for financial identity migration. A plan is not
# permission to publish: its row versions and ownership must be rechecked under
# the migration/account fences when immutable evidence is eventually captured.
class Provider::AccountData::Plaid::IdentityBootstrapPlan
  class InvalidContext < StandardError; end

  FORMAT = "plaid-financial-identity-v1".freeze
  MAX_PAGE_SIZE = 500
  MAX_ARCHIVE_BYTES = 32 * 1024 * 1024
  MAX_ARCHIVE_CHUNKS = 1_024
  CASH_TYPES = %w[cash fee transfer contribution withdrawal].freeze
  Page = Data.define(:document, :next_cursor, :complete) do
    def ready?
      document.fetch("blockers").empty?
    end

    # The document includes private, typed financial snapshots. Avoid accidental
    # console/support logging; eventual persistence must use encrypted payloads.
    def inspect
      "#<#{self.class.name} complete=#{complete} ready=#{ready?}>"
    end
  end

  def initialize(mapping:, family:)
    @mapping = mapping
    @family = family
  end

  def page(cursor: nil, limit: 100)
    validate_limit!(limit)

    validate_context!
    archive = verified_archive
    index = archive_index(archive.fetch("attributes"))
    binding = context_binding
    after_id = validate_cursor(cursor, binding)
    scope = candidates.order(:id)
    scope = scope.where("entries.id > ?", after_id) if after_id
    entries = scope.limit(limit + 1).includes(:entryable).to_a
    complete = entries.size <= limit
    rows, blockers = [], []
    entries.first(limit).each do |entry|
      row, error = plan_entry(entry, index)
      error ? blockers << { "entry_id" => entry.id, "code" => error } : rows << row
    end
    document = binding.merge(
      "after_entry_id" => after_id, "last_entry_id" => entries.first(limit).last&.id,
      "rows" => rows, "blockers" => blockers, "complete" => complete, "page_limit" => limit,
      "requires_quiesced_reverification" => true
    )
    # An unresolved row cannot disappear behind a successfully advanced cursor.
    next_cursor = binding.merge("after_entry_id" => document.fetch("last_entry_id")) if !complete && blockers.empty?
    Page.new(document: immutable(document), next_cursor: immutable(next_cursor), complete: complete)
  end

  # Final reconciliation must include blocked candidates and restart from nil:
  # UUID ordering cannot detect a later insertion behind a previous page boundary.
  def candidate_entry_ids(after_id: nil, limit: MAX_PAGE_SIZE)
    validate_limit!(limit)
    unless after_id.nil? || (after_id.is_a?(String) && after_id.match?(Provider::AccountData::LegacyWriterFence::UUID))
      raise InvalidContext, "Invalid financial identity continuation"
    end
    ApplicationRecord.uncached do
      validate_context!
      verified_archive
      scope = candidates.order(:id)
      scope = scope.where("entries.id > ?", after_id) if after_id
      immutable(scope.limit(limit).pluck(:id))
    end
  end

  def candidate_entries
    validate_context!
    verified_archive
    candidates
  end

  private
    attr_reader :mapping, :family, :account, :link, :external, :control

    def validate_limit!(limit)
      raise ArgumentError, "Invalid identity page size" unless limit.is_a?(Integer) && (1..MAX_PAGE_SIZE).cover?(limit)
    end

    def validate_context!
      @mapping = mapping.reload
      @control = mapping.provider_migration_control
      @external = mapping.external_account
      unless family&.persisted? && mapping.family_id == family.id && control.family_id == family.id &&
          mapping.role == "external_account" && mapping.legacy_type == "PlaidAccount" &&
          control.provider_key == "plaid" && control.legacy_type == "PlaidItem" &&
          mapping.verified_at && mapping.source_checksum.present? &&
          %w[shadow quiescing].include?(control.state) && external &&
          external.family_id == family.id && external.provider_key == "plaid" &&
          external.provider_connection_id == control.provider_connection_id && external.provider_connection.family_id == family.id &&
          external.provider_connection.disabled?
        raise InvalidContext, "Identity planning requires a verified disabled Plaid copy in this family"
      end
      @link = AccountProvider.find_by(external_account_id: external.id)
      @account = link&.account
      unless link && account && account.family_id == family.id && link.family_id == family.id &&
          link.provider_key == "plaid" && link.provider_type == "PlaidAccount" && link.provider_id == mapping.legacy_id
        raise InvalidContext, "Identity planning requires the retained Plaid account link"
      end
      competing = account.account_providers.where("provider_type = ? OR provider_key = ?", "PlaidAccount", "plaid").where.not(id: link.id)
      source = PlaidAccount.find_by(id: mapping.legacy_id, plaid_item_id: control.legacy_id)
      direct_accounts = Account.where(plaid_account_id: mapping.legacy_id)
      if competing.exists? || !source || source.plaid_item.family_id != family.id || source.current_account&.id != account.id ||
          direct_accounts.where.not(id: account.id).exists? ||
          (account.plaid_account_id.present? && account.plaid_account_id != mapping.legacy_id)
        raise InvalidContext, "Plaid financial ownership is ambiguous"
      end
    end

    def verified_archive
      archive = Provider::AccountData::MigrationCopier.new(provider_key: "plaid", legacy_item_id: control.legacy_id)
        .snapshot_for(mapping, max_bytes: MAX_ARCHIVE_BYTES, max_chunks: MAX_ARCHIVE_CHUNKS)
      Provider::AccountData::MigrationCopier.verify_account_binding!(archive: archive, link: link, financial: account)
      attributes = archive.fetch("attributes")
      unless archive["format"] == Provider::AccountData::MigrationCopier::SNAPSHOT_FORMAT &&
          archive["provider_key"] == "plaid" && archive["source_type"] == "PlaidAccount" &&
          archive["source_id"] == mapping.legacy_id && attributes["id"] == mapping.legacy_id &&
          attributes["plaid_item_id"] == control.legacy_id && attributes["plaid_id"] == external.external_id
        raise InvalidContext, "Plaid archive does not match the copied account"
      end
      archive
    rescue Provider::AccountData::MigrationCopier::Conflict
      raise InvalidContext, "Plaid archive is invalid or exceeds its read bound", cause: nil
    end

    def context_binding
      {
        "format" => FORMAT, "family_id" => family.id, "source" => "plaid",
        "provider_connection_id" => external.provider_connection_id, "external_account_id" => external.id,
        "account_id" => account.id, "account_provider_id" => link.id,
        "migration_mapping_id" => mapping.id, "legacy_account_id" => mapping.legacy_id,
        "archive_checksum" => mapping.source_checksum, "writer_epoch" => control.writer_epoch,
        "connection_writer_epoch" => external.provider_connection.writer_epoch,
        "region" => external.provider_connection.region, "environment" => external.provider_connection.environment,
        "credential_revision" => external.provider_connection.credential_revision
      }
    end

    def validate_cursor(cursor, binding)
      return nil if cursor.nil?
      unless cursor.is_a?(Hash) && cursor.except("after_entry_id") == binding &&
          cursor["after_entry_id"].is_a?(String) && cursor["after_entry_id"].match?(/\A[0-9a-f-]{36}\z/i)
        raise InvalidContext, "Identity continuation belongs to a different copied account"
      end
      cursor.fetch("after_entry_id")
    end

    def candidates
      account.entries.where("source = ? OR plaid_id IS NOT NULL", "plaid")
    end

    def archive_index(attributes)
      index = Hash.new { |hash, key| hash[key] = [] }
      @archived_pending_aliases = Hash.new { |hash, key| hash[key] = [] }
      transactions = attributes["raw_transactions_payload"] || {}
      investments = attributes["raw_holdings_payload"] || {}
      raise InvalidContext, "Malformed Plaid identity archive" unless transactions.is_a?(Hash) && investments.is_a?(Hash)
      %w[added modified removed].each do |section|
        archive_rows(transactions[section]).each_with_index do |raw, position|
          check_archived_account!(raw)
          id = identifier(raw["transaction_id"])
          proof = { "kind" => "transaction", "entryable_type" => "Transaction",
            "path" => [ "raw_transactions_payload", section, position ], "current_id" => id }
          index[id] << proof
          pending_id = optional_identifier(raw["pending_transaction_id"])
          if pending_id && pending_id != id && raw["pending"] == false
            index[pending_id] << proof.merge("pending_alias" => true)
            @archived_pending_aliases[id] << pending_id
          end
        end
      end
      archive_rows(investments["transactions"]).each_with_index do |raw, position|
        check_archived_account!(raw)
        id = identifier(raw["investment_transaction_id"])
        index[id] << { "kind" => "activity", "entryable_type" => CASH_TYPES.include?(raw["type"]) ? "Transaction" : "Trade",
          "path" => [ "raw_holdings_payload", "transactions", position ], "current_id" => id }
      end
      index
    rescue ArgumentError
      raise InvalidContext, "Malformed Plaid identity archive", cause: nil
    end

    def archive_rows(value)
      return [] if value.nil?
      raise InvalidContext, "Malformed Plaid identity archive" unless value.is_a?(Array) && value.all? { |row| row.is_a?(Hash) }
      value
    end

    def check_archived_account!(raw)
      if raw.key?("account_id") && raw["account_id"] != external.external_id
        raise InvalidContext, "Plaid archive contains another account's identity"
      end
    end

    def plan_entry(entry, index)
      return [ nil, "unsupported_entry_type" ] unless %w[Transaction Trade].include?(entry.entryable_type) && entry.entryable
      return [ nil, "conflicting_source" ] if entry.source.present? && entry.source != "plaid"
      external_id = optional_identifier(entry.external_id)
      plaid_id = optional_identifier(entry.plaid_id)
      return [ nil, "unscoped_external_id" ] if external_id && entry.source != "plaid" && external_id != plaid_id
      current_id = external_id || plaid_id
      return [ nil, "missing_identity" ] unless current_id

      extra = entry.transaction? ? entry.transaction.extra : {}
      return [ nil, "malformed_pending_aliases" ] unless extra.nil? || extra.is_a?(Hash)
      extra ||= {}
      plaid_extra = extra["plaid"]
      return [ nil, "malformed_pending_aliases" ] unless plaid_extra.nil? || plaid_extra.is_a?(Hash)
      if plaid_extra&.key?("pending") && ![ nil, true, false ].include?(plaid_extra["pending"])
        return [ nil, "malformed_pending_state" ]
      end
      claimed = extra["auto_claimed_pending_ids"] || []
      return [ nil, "malformed_pending_aliases" ] unless claimed.is_a?(Array) && claimed.all? { |id| valid_identifier?(id) }
      pending_id = optional_identifier(plaid_extra&.fetch("pending_transaction_id", nil))
      aliases = (claimed + [ pending_id ].compact).uniq - [ current_id ]
      aliases += @archived_pending_aliases.fetch(current_id, [])
      aliases.uniq!
      if plaid_id && plaid_id != current_id && !aliases.include?(plaid_id)
        return [ nil, "divergent_legacy_identity" ]
      end
      ids = [ current_id, *aliases ]
      proofs = ids.flat_map { |id| index[id] }
      unapplied = proofs.select { |proof| proof["pending_alias"] && proof["current_id"] != current_id && !ids.include?(proof["current_id"]) }
      if unapplied.any?
        # A cached settlement is not proof that the legacy processor applied it.
        # Preserve an explicit, unambiguous pending identity for a future fresh
        # observation, without claiming the cached booked ID or its alias proof.
        unless entry.transaction? && plaid_extra&.fetch("pending", nil) == true && aliases.empty?
          return [ nil, "pending_transition_not_applied" ]
        end
      end
      kinds = proofs.map { |proof| proof["kind"] }.uniq
      types = proofs.map { |proof| proof["entryable_type"] }.uniq
      return [ nil, "conflicting_archive_identity" ] if kinds.size > 1 || types.any? { |type| type != entry.entryable_type }
      proofs -= unapplied
      kind = kinds.first || (entry.trade? ? "activity" : plaid_extra.present? ? "transaction" : nil)
      return [ nil, "unresolved_stream" ] unless kind
      return [ nil, "activity_has_pending_aliases" ] if kind == "activity" && aliases.any?
      return [ nil, "identity_claimed_by_multiple_entries" ] if identity_collision?(entry, ids)
      return [ nil, "conflicting_native_evidence" ] if evidence_collision?(entry, ids, kind)

      snapshot = { "entry" => entry.attributes, "entryable" => entry.entryable.attributes }
      serialized = Provider::AccountData::MigrationValue.dump(snapshot)
      row = {
        "entry_id" => entry.id, "entryable_type" => entry.entryable_type, "kind" => kind,
        "external_id" => current_id, "pending_aliases" => aliases.sort,
        "pending" => kind == "transaction" && plaid_extra&.fetch("pending", false) == true,
        "identity_columns" => entry.attributes.slice("plaid_id", "external_id", "source"),
        "match_method" => external_id ? "legacy_external_id" : "legacy_plaid_id",
        "archive_paths" => proofs.map { |proof| proof.fetch("path") }.uniq,
        "financial_snapshot" => Provider::AccountData::MigrationValue.encode(snapshot),
        "financial_checksum" => Digest::SHA256.hexdigest(serialized)
      }
      [ row, nil ]
    rescue ArgumentError
      [ nil, "malformed_identity" ]
    end

    def identity_collision?(entry, ids)
      others = candidates.where.not(id: entry.id)
      return true if others.where("external_id IN (?) OR plaid_id IN (?)", ids, ids).exists?
      # Check every Entry, including rows outside this bounded page. Pending
      # aliases have no database uniqueness constraint in the legacy JSON.
      others.joins("INNER JOIN transactions ON transactions.id = entries.entryable_id AND entries.entryable_type = 'Transaction'")
        .where("transactions.extra -> 'auto_claimed_pending_ids' ?| ARRAY[:ids] OR transactions.extra -> 'plaid' ->> 'pending_transaction_id' IN (:ids)", ids: ids).exists?
    end

    def evidence_collision?(entry, ids, kind)
      SourceRecord.where(external_account: external, external_id: ids).includes(:entry_sources).any? do |record|
        record.kind != kind || record.withdrawn? || (record.account_id.present? && record.account_id != account.id) || record.entry_sources.any? do |evidence|
          !evidence.active? || evidence.entry_id != entry.id || evidence.role != "posting"
        end
      end
    end

    def optional_identifier(value)
      return nil if value.nil?
      identifier(value)
    end

    def identifier(value)
      raise ArgumentError, "Invalid Plaid identifier" unless valid_identifier?(value)
      value
    end

    def valid_identifier?(value)
      value.is_a?(String) && value.present?
    end

    def immutable(value)
      Provider::AccountData::MigrationManifest.copy_value(value)
    end
end
