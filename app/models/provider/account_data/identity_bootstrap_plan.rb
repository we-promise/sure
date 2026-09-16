require "digest"

# Read-only adoption plan for reviewed source + external_id conventions. Existing
# Entries are the financial truth; the account archive proves copied ownership,
# not that the latest provider payload is a complete historical transaction list.
class Provider::AccountData::IdentityBootstrapPlan
  class InvalidContext < StandardError; end

  FORMAT = "provider-financial-identity-plan-v1".freeze
  MAX_PAGE_SIZE = 500
  MAX_ARCHIVE_BYTES = 32 * 1024 * 1024
  MAX_ARCHIVE_CHUNKS = 1_024
  MAX_FINANCIAL_BYTES = 16 * 1024 * 1024
  MAX_DOCUMENT_BYTES = 96 * 1024 * 1024
  MAX_ALIASES = 100
  UUID = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i
  Page = Data.define(:document, :next_cursor, :complete) do
    def ready?
      document.fetch("blockers").empty?
    end

    def inspect
      "#<#{self.class.name} complete=#{complete} ready=#{ready?}>"
    end
  end

  def initialize(mapping:, family:)
    @mapping, @family = mapping, family
  end

  def page(cursor: nil, limit: 100)
    validate_limit!(limit)
    ApplicationRecord.uncached do
      prepare_context!
      binding = context_binding
      after_id = validate_cursor(cursor, binding)
      scope = candidate_scope.order(:id)
      scope = scope.where("entries.id > ?", after_id) if after_id
      inventory = scope.limit(limit + 1).pluck(:id, :entryable_type, :entryable_id,
        Arel.sql("COALESCE(octet_length(to_jsonb(entries)::text), 0)"))
      complete = inventory.size <= limit
      selected = inventory.first(limit)
      check_financial_bound!(selected)
      entries = account.entries.where(id: selected.map(&:first)).order(:id).to_a
      unless entries.map { |entry| [ entry.id, entry.entryable_type, entry.entryable_id ] } == selected.map { |id, type, entryable_id, _| [ id, type, entryable_id ] }
        raise InvalidContext, "Financial identity inventory changed during planning"
      end
      ActiveRecord::Associations::Preloader.new(records: entries.select { |entry| %w[Transaction Trade].include?(entry.entryable_type) }, associations: :entryable).call
      rows, blockers = [], []
      entries.each do |entry|
        row, code = plan_entry(entry)
        code ? blockers << { "entry_id" => entry.id, "code" => code } : rows << row
      end
      document = binding.merge("after_entry_id" => after_id, "last_entry_id" => entries.last&.id,
        "rows" => rows, "blockers" => blockers, "complete" => complete, "page_limit" => limit,
        "requires_quiesced_reverification" => true)
      if Value.dump(document).bytesize > MAX_DOCUMENT_BYTES
        raise InvalidContext, "Financial identity document exceeds its read bound"
      end
      continuation = binding.merge("after_entry_id" => entries.last.id) if !complete && blockers.empty?
      Page.new(document: immutable(document), next_cursor: immutable(continuation), complete: complete)
    end
  end

  # Public bounded enumeration for the publisher's final quiesced sweep. It uses
  # the very same reviewed candidate predicate as page, including blocked rows.
  # UUID order is not a change feed: a final sweep must start again from nil.
  def candidate_entry_ids(after_id: nil, limit: MAX_PAGE_SIZE)
    validate_limit!(limit)
    raise InvalidContext, "Invalid financial identity continuation" unless after_id.nil? || valid_uuid?(after_id)
    ApplicationRecord.uncached do
      prepare_context!
      scope = candidate_scope.order(:id)
      scope = scope.where("entries.id > ?", after_id) if after_id
      immutable(scope.limit(limit).pluck(:id))
    end
  end

  # Used by the publisher's terminal SQL anti-join. The returned relation retains
  # the authorized account and exactly the same predicate, including blockers.
  def candidate_entries
    prepare_context!
    candidate_scope
  end

  private
    Value = Provider::AccountData::MigrationValue
    attr_reader :mapping, :family, :manifest, :legacy_manifest, :control, :external, :connection, :link, :account, :source_account

    def prepare_context!
      @mapping = mapping.reload
      @control = mapping.provider_migration_control.reload
      @manifest = Provider::AccountData::FinancialIdentityManifest.for(control.provider_key)
      raise InvalidContext, "Plaid identities require the specialized reviewed planner" if manifest.specialized?
      @legacy_manifest = manifest.legacy_manifest
      @external = mapping.external_account
      @connection = external&.provider_connection
      unless family&.persisted? && mapping.family_id == family.id && control.family_id == family.id &&
          mapping.role == "external_account" && mapping.legacy_type == legacy_manifest.account_type &&
          control.legacy_type == legacy_manifest.item_type && mapping.verified_at && mapping.source_checksum.present? &&
          control.copy_version == Provider::AccountData::MigrationManifest::VERSION && %w[shadow quiescing].include?(control.state) &&
          external && external.family_id == family.id && external.provider_key == manifest.provider_key &&
          connection && connection.id == control.provider_connection_id && connection.family_id == family.id &&
          connection.provider_key == manifest.provider_key && connection.disabled? && !connection.scheduled_for_deletion
        raise InvalidContext, "Identity planning requires a verified disabled copy in this family"
      end
      # Class names are produced only by the reviewed migration manifest.
      item = legacy_manifest.item_type.constantize.find_by(id: control.legacy_id, family_id: family.id)
      source_scope = legacy_manifest.account_type.constantize.where(id: mapping.legacy_id, legacy_manifest.account_foreign_key => control.legacy_id)
      source_table = source_scope.klass.connection.quote_table_name(source_scope.klass.table_name)
      source_bytes = source_scope.pick(Arel.sql("COALESCE(octet_length(to_jsonb(#{source_table})::text), 0)"))
      if source_bytes && source_bytes > MAX_ARCHIVE_BYTES
        raise InvalidContext, "Legacy account exceeds its identity planning read bound"
      end
      @source_account = source_scope.where("octet_length(to_jsonb(#{source_table})::text) <= ?", MAX_ARCHIVE_BYTES).first
      @link = AccountProvider.find_by(external_account_id: external.id)
      @account = link&.account
      unless item && source_account && link && account && account.family_id == family.id && link.family_id == family.id &&
          link.provider_key == manifest.provider_key && link.provider_type == legacy_manifest.account_type && link.provider_id == mapping.legacy_id &&
          source_account.current_account&.id == account.id
        raise InvalidContext, "Identity planning requires the retained legacy financial account link"
      end
      competitors = account.account_providers.where("provider_type = ? OR provider_key = ?", legacy_manifest.account_type, manifest.provider_key).where.not(id: link.id)
      raise InvalidContext, "Financial source ownership is ambiguous" if competitors.exists?
      direct_column = "#{manifest.provider_key}_account_id"
      if Account.column_names.include?(direct_column) &&
          ((account[direct_column].present? && account[direct_column] != mapping.legacy_id) ||
           Account.where(direct_column => mapping.legacy_id).where.not(id: account.id).exists?)
        raise InvalidContext, "Direct legacy financial ownership is ambiguous"
      end
      verify_archive!
    rescue Provider::AccountData::MigrationCopier::Conflict, Provider::AccountData::MigrationManifest::InvalidSource, ArgumentError
      raise InvalidContext, "Copied identity context is invalid or exceeds its read bound", cause: nil
    end

    def verify_archive!
      archive = Provider::AccountData::MigrationCopier.new(provider_key: manifest.provider_key, legacy_item_id: control.legacy_id)
        .snapshot_for(mapping, max_bytes: MAX_ARCHIVE_BYTES, max_chunks: MAX_ARCHIVE_CHUNKS)
      Provider::AccountData::MigrationCopier.verify_account_binding!(archive: archive, link: link, financial: account)
      projection = legacy_manifest.extract_account(source_account)
      unless archive["format"] == Provider::AccountData::MigrationCopier::SNAPSHOT_FORMAT &&
          archive["manifest_version"] == Provider::AccountData::MigrationManifest::VERSION && archive["provider_key"] == manifest.provider_key &&
          archive["source_type"] == legacy_manifest.account_type && archive["source_table"] == legacy_manifest.account_table &&
          archive["source_id"] == mapping.legacy_id && projection.external_id.present? && projection.external_id == external.external_id &&
          projection.identity_namespace == external.identity_namespace &&
          Value.dump(archive.fetch("attributes")) == Value.dump(projection.source_attributes)
        raise InvalidContext, "The current legacy account differs from its verified typed archive"
      end
      @archive_columns = manifest.archive_columns
    end

    def context_binding
      { "format" => FORMAT, "manifest_version" => Provider::AccountData::FinancialIdentityManifest::VERSION,
        "provider_key" => manifest.provider_key, "source" => manifest.source, "family_id" => family.id,
        "provider_connection_id" => connection.id, "external_account_id" => external.id, "external_account_external_id" => external.external_id,
        "identity_namespace" => external.identity_namespace, "account_id" => account.id,
        "account_provider_id" => link.id, "account_provider_revision" => link.lock_version,
        "account_currency" => account.currency, "accountable_type" => account.accountable_type, "accountable_id" => account.accountable_id,
        "migration_mapping_id" => mapping.id, "legacy_account_id" => mapping.legacy_id, "archive_checksum" => mapping.source_checksum,
        "archive_columns" => @archive_columns, "writer_epoch" => control.writer_epoch, "connection_writer_epoch" => connection.writer_epoch,
        "copy_run_id" => control.high_water_mark["copy_run_id"], "region" => connection.region, "environment" => connection.environment,
        "credential_revision" => connection.credential_revision }
    end

    def candidate_scope
      scope = account.entries.where(source: manifest.source)
      manifest.candidate_prefixes.each do |prefix|
        scope = scope.or(account.entries.where("entries.external_id LIKE ?", "#{Entry.sanitize_sql_like(prefix)}%"))
      end
      scope
    end

    def plan_entry(entry)
      return [ nil, "unsupported_entry_type" ] unless %w[Transaction Trade].include?(entry.entryable_type) && entry.entryable
      return [ nil, "conflicting_source" ] unless entry.source == manifest.source
      return [ nil, "foreign_legacy_identity" ] if entry.plaid_id.present?
      id = entry.external_id
      return [ nil, "missing_identity" ] unless valid_identifier?(id)
      rule = manifest.rule_for(id, legacy_account_id: mapping.legacy_id)
      return [ nil, "unreviewed_identity_form" ] unless rule
      unless rule.entryable_types.include?(entry.entryable_type)
        code = manifest.provider_key == "onchain_wallet" && entry.transaction? ? "financial_type_transition_requires_review" : "incompatible_financial_type"
        return [ nil, code ]
      end
      aliases, pending, code = pending_identity(entry, rule.kind)
      return [ nil, code ] if code
      ids = [ id, *aliases ]
      return [ nil, "unresolved_input_occurrence" ] if ids.any? { |identity| ambiguous_occurrence?(identity, entry) }
      return [ nil, "identity_claimed_by_multiple_entries" ] if identity_collision?(entry, ids)
      return [ nil, "conflicting_native_evidence" ] if evidence_collision?(entry, ids, rule.kind)
      if manifest.provider_key == "coinstats" && entry.transaction? && coinstats_type_transition?(entry)
        return [ nil, "financial_type_transition_requires_review" ]
      end
      snapshot = { "entry" => entry.attributes, "entryable" => entry.entryable.attributes }
      serialized = Value.dump(snapshot)
      identities = ids.map do |identity|
        current = identity == id
        { "external_id" => identity, "input_external_id" => identity, "input_occurrence" => 0,
          "role" => current ? "current" : "retired_alias", "pending" => current ? pending : false }
      end
      [ { "entry_id" => entry.id, "entryable_type" => entry.entryable_type, "kind" => rule.kind,
          "external_id" => id, "pending_aliases" => aliases, "pending" => pending, "identities" => identities,
          "identity_columns" => entry.attributes.slice("plaid_id", "external_id", "source"),
          "match_method" => "legacy_external_id", "archive_paths" => [],
          "financial_snapshot" => Value.encode(snapshot), "financial_checksum" => Digest::SHA256.hexdigest(serialized) }, nil ]
    rescue ArgumentError, TypeError
      [ nil, "malformed_identity" ]
    end

    def pending_identity(entry, kind)
      return [ [], false, nil ] unless entry.transaction?
      extra = entry.transaction.extra || {}
      return [ nil, nil, "malformed_pending_state" ] unless extra.is_a?(Hash)
      own = extra[manifest.source]
      return [ nil, nil, "malformed_pending_state" ] unless own.nil? || own.is_a?(Hash)
      flag = own&.fetch("pending", nil)
      return [ nil, nil, "malformed_pending_state" ] unless [ nil, true, false ].include?(flag)
      if flag == true && !Transaction::PENDING_PROVIDERS.include?(manifest.source)
        return [ nil, nil, "unreviewed_pending_state" ]
      end
      foreign_pending = Transaction::PENDING_PROVIDERS.reject { |source| source == manifest.source }.any? do |source|
        data = extra[source]
        data && (!data.is_a?(Hash) || ![ nil, false ].include?(data["pending"]))
      end
      return [ nil, nil, "foreign_pending_state" ] if foreign_pending
      aliases = extra["auto_claimed_pending_ids"] || []
      unless aliases.is_a?(Array) && aliases.size <= MAX_ALIASES && aliases.all? { |id| valid_identifier?(id) }
        return [ nil, nil, "malformed_pending_aliases" ]
      end
      aliases = aliases.uniq.sort - [ entry.external_id ]
      unless aliases.all? { |id| manifest.rule_for(id, legacy_account_id: mapping.legacy_id)&.kind == kind }
        return [ nil, nil, "foreign_pending_alias" ]
      end
      if kind != "transaction" && (flag == true || aliases.any?)
        return [ nil, nil, "activity_has_pending_aliases" ]
      end
      [ aliases, flag == true, nil ]
    end

    def ambiguous_occurrence?(id, entry)
      base = manifest.occurrence_base(id)
      return false unless base
      return true if base != id
      candidate_scope.where.not(id: entry.id).where("entries.external_id LIKE ?", "#{Entry.sanitize_sql_like("#{base}_")}%").exists?
    end

    def identity_collision?(entry, ids)
      others = candidate_scope.where.not(id: entry.id)
      return true if others.where(external_id: ids).exists?
      others.joins("INNER JOIN transactions ON transactions.id = entries.entryable_id AND entries.entryable_type = 'Transaction'")
        .where("transactions.extra -> 'auto_claimed_pending_ids' ?| ARRAY[:ids]", ids: ids).exists?
    end

    def evidence_collision?(entry, ids, kind)
      return true if EntrySource.where(active: true, entry_id: entry.id, role: "posting").joins(:source_record)
        .where.not(source_records: { external_account_id: external.id }).exists?
      SourceRecord.where(external_account: external, external_id: ids).includes(:entry_sources).any? do |record|
        record.kind != kind || record.family_id != family.id || (record.account_id.present? && record.account_id != account.id) ||
          (record.external_id == entry.external_id && record.withdrawn?) || record.entry_sources.any? do |evidence|
            !evidence.active? || evidence.entry_id != entry.id || evidence.account_id != account.id || evidence.family_id != family.id || evidence.role != "posting"
          end
      end
    end

    def coinstats_type_transition?(entry)
      descriptor = external.sensitive_details["source_descriptor"] || {}
      type = entry.transaction.extra&.dig("coinstats", "transaction_type")
      descriptor["source"] == "exchange" && descriptor["fiat"] != true &&
        type.is_a?(String) && %w[buy sell swap trade convert fill].include?(type.downcase.parameterize(separator: "_"))
    end

    def check_financial_bound!(inventory)
      size = inventory.sum { |_, _, _, bytes| bytes.to_i }
      { "Transaction" => Transaction, "Trade" => Trade }.each do |type, model|
        ids = inventory.filter_map { |_, entry_type, id, _| id if entry_type == type }
        if Entry.where(entryable_type: type, entryable_id: ids).group(:entryable_id).having("COUNT(*) > 1").exists?
          raise InvalidContext, "Financial identity has ambiguous entryable ownership"
        end
        table = model.connection.quote_table_name(model.table_name)
        size += model.where(id: ids).pluck(Arel.sql("COALESCE(octet_length(to_jsonb(#{table})::text), 0)")).sum(&:to_i)
      end
      raise InvalidContext, "Financial identity page exceeds its read bound" if size > MAX_FINANCIAL_BYTES
    end

    def validate_cursor(cursor, binding)
      return unless cursor
      unless cursor.is_a?(Hash) && cursor.except("after_entry_id") == binding && valid_uuid?(cursor["after_entry_id"])
        raise InvalidContext, "Identity continuation belongs to another copied account or revision"
      end
      cursor.fetch("after_entry_id")
    end

    def validate_limit!(limit)
      raise ArgumentError, "Invalid identity page size" unless limit.is_a?(Integer) && (1..MAX_PAGE_SIZE).cover?(limit)
    end

    def valid_uuid?(value)
      value.is_a?(String) && UUID.match?(value)
    end

    def valid_identifier?(value)
      value.is_a?(String) && value.present? && value.bytesize <= 8_192
    end

    def immutable(value)
      Provider::AccountData::MigrationManifest.copy_value(value)
    end
end
