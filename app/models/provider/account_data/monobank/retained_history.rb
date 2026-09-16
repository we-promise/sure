# Original statement coverage and held transactions are distinct from native
# checkpoint progress. This collector reads accepted archives, never a legacy
# provider client or processor, and makes no coverage or financial writes.
class Provider::AccountData::Monobank::RetainedHistory
  VERSION = 1
  MAX_ACCOUNTS = 1_000
  MAX_ARCHIVE_BYTES = 32 * 1024 * 1024
  MAX_TRANSACTIONS = 100_000
  MAX_CHECKPOINT_BYTES = 64 * 1024
  BOUNDARY_COLUMNS = %w[history_synced_from statement_synced_through].freeze

  def self.live_input(connection:)
    new(connection).live_input
  end

  def self.build(connection:, observed_at:, external_accounts: nil)
    new(connection).build(observed_at: observed_at, external_accounts: external_accounts)
  end

  def initialize(connection)
    @connection = connection
    @reader = Provider::AccountData::RetainedRow.new(connection: connection, provider_key: "monobank")
  end

  # Header/checkpoint provenance is checked before every request and publication.
  # Native transaction cursor, progress and covered_through are deliberately not
  # included: advancing them must not replace or invalidate the retained seed.
  def live_input
    require_admission!
    rows = linked_sources.to_h do |external|
      descriptor = reader.account_descriptor(external)
      checkpoint = legacy_checkpoint(external, descriptor)
      link = external.account_provider
      financial = external.current_account
      [ external.id, {
        "external_id" => external.external_id, "identity_namespace" => external.identity_namespace,
        "status" => external.status, "financial_status" => financial.status,
        "sync_start_date" => external.sync_start_date&.iso8601,
        "account_binding" => { "format" => Copier::ACCOUNT_BINDING_FORMAT,
          "link" => link.attributes.slice(*Copier::RETAINED_LINK_COLUMNS),
          "financial_context" => financial.attributes.slice(*Copier::RETAINED_FINANCIAL_CONTEXT_COLUMNS) },
        "source" => descriptor, "legacy_state" => checkpoint
      } ]
    end
    Manifest.copy_value("version" => VERSION, "family_id" => connection.family_id, "item" => reader.item_descriptor,
      "provider_connection_id" => connection.id, "accounts" => rows)
  rescue ActiveRecord::RecordNotFound, ActiveRecord::SoleRecordExceeded, KeyError, ArgumentError, TypeError
    raise Provider::AccountData::StaleWriter, "Monobank retained history context is missing or invalid", cause: nil
  end

  # Only factory construction reads transaction archives. Later proof checks use
  # live_input's immutable source checksum and exact copied checkpoint instead.
  def build(observed_at:, external_accounts: nil)
    raise Provider::AccountData::StaleWriter, "Monobank history requires its observation time" unless observed_at.is_a?(Time) || observed_at.is_a?(DateTime)
    input = live_input
    externals = linked_sources.index_by(&:id)
    if external_accounts
      supplied = external_accounts.select { |external| external.current_account }.map(&:id).sort
      unless supplied == externals.keys.sort && external_accounts.all? { |external| external.family_id == connection.family_id && external.provider_connection_id == connection.id }
        raise Provider::AccountData::StaleWriter, "Monobank history account inventory changed"
      end
    end
    total_bytes = 0
    rows = input.fetch("accounts").to_h do |id, context|
      external = externals.fetch(id)
      retained = reader.account(external)
      state = {}
      if context.fetch("source")
        unless retained && retained.context == context.fetch("source")
          raise Provider::AccountData::StaleWriter, "Monobank retained archive changed during construction"
        end
        total_bytes += retained.byte_size
        raise Provider::AccountData::IncompletePage, "Monobank retained history exceeds its capture bound" if total_bytes > MAX_ARCHIVE_BYTES
        Copier.verify_account_binding!(archive: retained.archive, link: external.account_provider, financial: external.current_account)
        attributes = retained.attributes
        unless attributes.values_at("id", "account_id", "monobank_item_id") ==
            [ retained.context.fetch("legacy_id"), external.external_id, input.fetch("item").fetch("legacy_id") ] &&
            external.identity_namespace == "connection"
          raise Provider::AccountData::StaleWriter, "Monobank retained history has a different account identity"
        end
        columns = Value.decode(context.fetch("legacy_state").fetch("state").fetch("columns"))
        unless columns == attributes.slice(*BOUNDARY_COLUMNS)
          raise Provider::AccountData::StaleWriter, "Monobank copied statement coverage differs from its source archive"
        end
        state = columns.transform_values { |value| value&.getutc&.iso8601(9) }
        state["oldest_pending_at"] = oldest_hold(attributes.fetch("raw_transactions_payload"))
      elsif retained
        raise Provider::AccountData::StaleWriter, "Monobank retained source appeared during construction"
      end
      [ id, { "context" => context, "state" => state } ]
    end
    Manifest.copy_value(input.except("accounts").merge("accounts" => rows))
  rescue Copier::Conflict, KeyError, ArgumentError, TypeError, NoMethodError
    raise Provider::AccountData::StaleWriter, "Monobank retained history archive is missing or invalid", cause: nil
  end

  def inspect
    "#<#{self.class.name}>"
  end

  private
    Copier = Provider::AccountData::MigrationCopier
    Manifest = Provider::AccountData::MigrationManifest
    Value = Provider::AccountData::MigrationValue
    attr_reader :connection, :reader

    def require_admission!
      unless connection.persisted? && connection.provider_key == "monobank" && ProviderConnection.connection.open_transactions.positive?
        raise Provider::AccountData::StaleWriter, "Monobank history requires its admitted connection transaction"
      end
    end

    def linked_sources
      sources = connection.external_accounts.where(family_id: connection.family_id).order(:id).limit(MAX_ACCOUNTS + 1).to_a
      raise Provider::AccountData::IncompletePage, "Monobank account inventory exceeds its capture bound" if sources.size > MAX_ACCOUNTS
      linked = sources.select { |external| external.account_provider }
      linked.each do |external|
        link, financial = external.account_provider, external.current_account
        unless link.family_id == connection.family_id && link.provider_key == "monobank" && financial &&
            financial.family_id == connection.family_id && external.external_id.present?
          raise Provider::AccountData::StaleWriter, "Monobank linked account permissions changed"
        end
      end
      unless linked.map { |external| [ external.identity_namespace, external.external_id ] }.uniq.size == linked.size
        raise Provider::AccountData::StaleWriter, "Monobank account history identity is ambiguous"
      end
      linked
    end

    def legacy_checkpoint(external, descriptor)
      expected_scope = descriptor && "MonobankAccount:#{descriptor.fetch('legacy_id')}"
      scope = connection.provider_sync_checkpoints.where(stream: "legacy_state")
        .where("external_account_id = ? OR scope_key = ?", external.id, expected_scope)
      headers = scope.limit(2).pluck(:id, Arel.sql("octet_length(state)"))
      return nil if descriptor.nil? && headers.empty?
      unless descriptor && descriptor.values_at("provider_key", "family_id", "provider_connection_id", "legacy_type", "role", "target_id") ==
          [ "monobank", connection.family_id, connection.id, "MonobankAccount", "external_account", external.id ] &&
          headers.one? && headers.sole.last.to_i <= MAX_CHECKPOINT_BYTES * 2
        raise Provider::AccountData::StaleWriter, "Monobank retained statement checkpoint is missing or ambiguous"
      end
      checkpoint = scope.where("octet_length(state) <= ?", MAX_CHECKPOINT_BYTES * 2).find(headers.sole.first)
      unless checkpoint.family_id == connection.family_id && checkpoint.external_account_id == external.id && checkpoint.scope_key == expected_scope &&
          checkpoint.provider_authorization_id.nil? && checkpoint.provider_sync_generation_id.nil? && checkpoint.ingestion_batch_id.nil? &&
          checkpoint.cursor.nil? && checkpoint.covered_through.nil? && checkpoint.schema_version == Manifest::VERSION &&
          checkpoint.state.keys.sort == %w[columns format] && checkpoint.state["format"] == Copier::SNAPSHOT_FORMAT &&
          Value.dump(checkpoint.state).bytesize <= MAX_CHECKPOINT_BYTES
        raise Provider::AccountData::StaleWriter, "Monobank retained checkpoint contains unrelated execution state"
      end
      columns = Value.decode(checkpoint.state.fetch("columns"))
      unless columns.is_a?(Hash) && columns.keys.sort == BOUNDARY_COLUMNS &&
          columns.values.all? { |value| value.nil? || value.is_a?(Time) }
        raise Provider::AccountData::StaleWriter, "Monobank retained checkpoint has invalid statement boundaries"
      end
      checkpoint.attributes.slice("id", "family_id", "provider_connection_id", "external_account_id", "stream", "scope_key", "schema_version", "state", "lock_version")
    end

    def oldest_hold(raw)
      rows = raw.nil? ? [] : raw
      unless rows.is_a?(Array) && rows.size <= MAX_TRANSACTIONS
        raise Provider::AccountData::IncompletePage, "Monobank retained transactions exceed their capture bound"
      end
      # Mirror oldest_stored_hold_time: Boolean casting, omitted timestamps and
      # legacy epoch to_i semantics. The adapter alone decides pending inclusion
      # and clamps this timestamp to Monobank's maximum statement window.
      oldest = rows.filter_map do |row|
        next unless row.is_a?(Hash)
        values = row.with_indifferent_access
        next unless ActiveModel::Type::Boolean.new.cast(values[:hold]) == true && values[:time].present?
        Time.at(values.fetch(:time).to_i).utc
      end.min
      oldest&.iso8601(9)
    end
end
