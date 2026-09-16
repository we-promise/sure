require "set"

# Provisional source discovery for the financial effects graph. This reads only
# identities/versions; admission, original-archive verification and locking must
# precede a fresh comparison and any destructive operation.
class Account::Destruction::Sources
  MAX_ROWS = 100_000
  MAX_ACCOUNTS = 100
  MAX_SYNC_DEPTH = 128
  MAX_EXPANSIONS = 32
  FORMAT = "account-destruction-sources/v1".freeze
  UUID = Provider::AccountData::LegacyWriterFence::UUID
  ACCOUNT_STREAMS = %w[transactions balances holdings activities equity_snapshots historical_balances opening_anchor_repairs].freeze
  HISTORICAL_STREAMS = %w[equity_snapshots historical_balances opening_anchor_repairs].freeze
  BINDING_ROUTING_SQL = <<~SQL.squish.freeze
    jsonb_typeof(source_binding) = 'object'
    AND source_binding ?& ARRAY['account_id', 'account_provider_id', 'external_account_id', 'resource', 'source_policy_version', 'publication']
    AND jsonb_typeof(source_binding->'external_account_id') = 'string'
    AND source_binding->>'external_account_id' = external_account_id::text
    AND jsonb_typeof(source_binding->'resource') = 'string' AND source_binding->>'resource' = stream
    AND source_binding->>'source_policy_version' IS NOT DISTINCT FROM source_policy_version
    AND (source_policy_version IS NULL OR EXISTS (
      SELECT 1 FROM account_source_policies binding_policy
      WHERE binding_policy.id::text = ingestion_batches.source_policy_version
        AND binding_policy.family_id = ingestion_batches.family_id
        AND binding_policy.account_id::text = source_binding->>'account_id'))
    AND ((source_binding->'account_id' = 'null'::jsonb
      AND source_binding->'account_provider_id' = 'null'::jsonb
      AND source_policy_version IS NULL AND source_binding->>'publication' = 'retained')
    OR (jsonb_typeof(source_binding->'account_id') = 'string'
      AND source_binding->>'account_id' ~* '^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$'
      AND jsonb_typeof(source_binding->'account_provider_id') = 'string'
      AND source_binding->>'account_provider_id' ~* '^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$'
      AND ((source_binding->>'publication' = 'retained' AND source_policy_version IS NULL)
        OR (source_binding->>'publication' = 'ledger' AND source_policy_version IS NOT NULL))))
  SQL

  class InvalidGraph < StandardError; end
  class Incomplete < InvalidGraph; end
  class TooLarge < InvalidGraph; end

  Snapshot = Data.define(:family_id, :root_account_id, :account_ids, :legacy_items, :legacy_accounts,
    :connection_ids, :external_ids, :control_ids, :mapping_ids, :document_ids, :import_ids, :proof)
  HEADERS = {
    "accounts" => [ Account, %w[id family_id plaid_account_id simplefin_account_id import_id updated_at] ],
    "account_identities" => [ Account::IngestionIdentity, %w[id family_id live_account_id retired_at updated_at] ],
    "entries" => [ Entry, %w[id account_id import_id reconciled_by_statement_id source updated_at] ],
    "holdings" => [ Holding, %w[id account_id account_provider_id updated_at] ],
    "links" => [ AccountProvider, %w[id account_id provider_type provider_id external_account_id family_id provider_key lock_version updated_at] ],
    "policies" => [ Account::SourcePolicy, %w[id family_id account_id account_provider_id resource revision active source_binding updated_at] ],
    "source_records" => [ SourceRecord, %w[id family_id account_id external_account_id account_statement_id ingestion_batch_id kind updated_at] ],
    "entry_sources" => [ EntrySource, %w[id family_id account_id source_record_id entry_id entry_identity bootstrap_batch_id bootstrap_external_account_id active updated_at] ],
    "holding_sources" => [ HoldingSource, %w[id family_id account_id source_record_id holding_id holding_identity active updated_at] ],
    "retained_bindings" => [ ProviderMigrationAccountBinding, %w[id family_id provider_migration_mapping_id first_batch_id financial_account_id account_provider_id source_checksum binding_state chunk_count created_at] ],
    "mappings" => [ ProviderMigrationMapping, %w[id family_id provider_migration_control_id role legacy_type legacy_id external_account_id updated_at] ],
    "generations" => [ ProviderSyncGeneration, %w[id family_id provider_connection_id sync_id stream status writer_epoch account_ids updated_at] ],
    "batches" => [ IngestionBatch, %w[id family_id origin_kind provider_connection_id provider_authorization_id external_account_id sync_id import_id account_statement_id stream scope_key source_policy_version provider_sync_generation_id generation_role generation_resource writer_epoch status updated_at] ],
    "syncs" => [ Sync, %w[id syncable_type syncable_id account_family_id parent_id predecessor_id status updated_at] ],
    "sync_inputs" => [ Account::SyncInput, %w[id family_id account_id sync_id provider_sync_id source_batch_id resource kind created_at] ],
    "sync_sources" => [ Account::SyncSource, %w[id family_id account_id account_sync_input_id resource updated_at] ],
    "sync_preparations" => [ Account::SyncPreparation, %w[id sync_id input_digest created_at] ],
    "imports" => [ Import, %w[id family_id account_id account_statement_id type updated_at] ],
    "import_mappings" => [ Import::Mapping, %w[id import_id mappable_type mappable_id type updated_at] ],
    "documents" => [ AccountStatement, %w[id family_id account_id suggested_account_id updated_at] ]
  }.transform_values { |model, columns| [ model, columns.freeze ].freeze }.freeze
  BINDING_FIELDS = %w[account_id account_provider_id external_account_id resource source_policy_version publication
    format balance_policy_version anchor_policy_version source_batch_id].freeze
  private_constant :HEADERS, :BINDING_FIELDS

  def self.capture(account:)
    new(account).capture
  end

  def initialize(account)
    @effects = Account::Destruction::Effects.capture(account: account)
    @family_id, @root_id = @effects.family_id, @effects.root_account_id
    @rows = HEADERS.keys.to_h { |kind| [ kind, {} ] }
    @row_count = 0
    @account_ids = Set.new(@effects.account_ids)
    @deleted_sync_ids = Set.new
    @item_types = Provider::AccountData::MigrationManifest.all.map(&:item_type).to_set
  end

  def capture
    ApplicationRecord.uncached do
      assert_index_coverage!
      add("entries", Entry.where(id: @effects.affected_entry_ids))
      add("documents", AccountStatement.where(id: @effects.statement_ids))
      MAX_EXPANSIONS.times do
        previous = [ @row_count, @account_ids.size, @deleted_sync_ids.size ]
        discover_accounts!
        discover_evidence!
        discover_documents!
        discover_batches!
        discover_syncs!
        next unless previous == [ @row_count, @account_ids.size, @deleted_sync_ids.size ]

        validate_references!
        owners = resolve_owners!
        validate_owner_references!(owners)
        return snapshot(owners)
      end
      raise TooLarge, "Account source inventory exceeds its expansion bound"
    end
  rescue Provider::AccountData::GenerationAccountIndex::Incomplete
    raise Incomplete, "Provider generation ownership is not fully indexed", cause: nil
  rescue Ingestion::HistoricalBalances::SourceBinding::Incomplete
    raise Incomplete, "Historical command ownership is not fully indexed", cause: nil
  rescue Account::Destruction::SourceOwners::TooLarge => error
    raise TooLarge, error.message, cause: nil
  rescue Account::Destruction::SourceOwners::DispositionRequired => error
    raise Incomplete, error.message, cause: nil
  rescue Account::Destruction::SourceOwners::InvalidGraph => error
    raise InvalidGraph, error.message, cause: nil
  end

  private
    def ids(kind) = @rows.fetch(kind).keys
    def rows(kind) = @rows.fetch(kind).values
    def values(kind, column) = rows(kind).filter_map { |row| row[column] }.uniq

    def add(kind, scope)
      model, columns = HEADERS.fetch(kind)
      table = model.connection.quote_table_name(model.table_name)
      fields = columns.map { |column| Arel.sql("#{table}.#{model.connection.quote_column_name(column)}") }
      names = columns + %w[row_version tuple_version]
      fields += [ Arel.sql("#{table}.xmin::text"), Arel.sql("#{table}.ctid::text") ]
      if kind == "batches"
        BINDING_FIELDS.each do |key|
          expression = "#{table}.source_binding->>'#{key}'"
          if %w[format balance_policy_version anchor_policy_version source_batch_id].include?(key)
            expression = "CASE WHEN #{table}.origin_kind = 'provider' AND #{table}.stream IN ('historical_balances', 'opening_anchor_repairs') THEN #{expression} END"
          end
          fields << Arel.sql(expression)
          names << "binding_#{key}"
        end
        fields << Arel.sql("#{table}.source_binding ? 'account_id'")
        names << "binding_captured"
      end
      result = scope.reorder(:id).limit(MAX_ROWS + 1).pluck(*fields)
      raise TooLarge, "Account source inventory exceeds its row bound" if result.size > MAX_ROWS
      result.each do |tuple|
        row = names.zip(tuple).to_h.transform_values { |value| value.respond_to?(:iso8601) ? value.iso8601(6) : value }
        previous = @rows.fetch(kind)[row.fetch("id")]
        raise InvalidGraph, "Account source inventory changed during capture" if previous && previous != row
        next if previous
        @row_count += 1
        raise TooLarge, "Account source inventory exceeds its row bound" if @row_count > MAX_ROWS
        if row.key?("family_id") && !row["family_id"].nil? && row["family_id"] != @family_id
          raise InvalidGraph, "Account source reference belongs to another family"
        end
        @rows.fetch(kind)[row.fetch("id")] = row
      end
      result.size
    end

    def require_rows(kind, wanted)
      wanted = wanted.compact.uniq
      return if wanted.empty?
      model = HEADERS.fetch(kind).first
      add(kind, model.where(id: wanted))
      raise InvalidGraph, "Account source reference is missing" unless (wanted - ids(kind)).empty?
    end

    def add_account_ids(wanted)
      wanted.compact.each do |id|
        raise InvalidGraph, "Account source has an invalid financial identity" unless id.is_a?(String) && id.match?(UUID)
        @account_ids.add(id)
      end
      raise TooLarge, "Account source inventory exceeds its account bound" if @account_ids.size > MAX_ACCOUNTS
    end

    def assert_index_coverage!
      if Provider::AccountData::RetainedAccountIndex.unindexed_chunks(family_id: @family_id).exists?
        raise Incomplete, "Retained provider ownership is not fully indexed"
      end
      Provider::AccountData::GenerationAccountIndex.assert_complete_for!(family_id: @family_id)
      Ingestion::HistoricalBalances::SourceBinding.assert_complete_for!(family_id: @family_id)
      scope = IngestionBatch.where(family_id: @family_id, origin_kind: "provider")
      orphan_policy = scope.where.not(source_policy_version: nil).where(<<~SQL.squish)
        NOT EXISTS (SELECT 1 FROM account_source_policies policy
          WHERE policy.id::text = ingestion_batches.source_policy_version
            AND policy.family_id = ingestion_batches.family_id)
      SQL
      raise Incomplete, "Captured provider policy ownership is unresolved" if orphan_policy.exists?
      # Account-scoped publication captures must distinguish explicit unlinked
      # ownership from missing evidence. Policy-only IBKR captures are covered
      # by the retained policy; current external links cannot fill this gap.
      missing = scope.where(stream: ACCOUNT_STREAMS).where.not(external_account_id: nil)
        .where(source_policy_version: nil).where("NOT (source_binding ? 'account_id')")
      raise Incomplete, "Captured provider account ownership is unresolved" if missing.exists?
      malformed = scope.where.not(source_binding: {}).where("NOT COALESCE((#{BINDING_ROUTING_SQL}), FALSE)")
      raise Incomplete, "Captured provider routing is malformed or inconsistent" if malformed.exists?
      assert_historical_policy_coverage!(scope)
    end

    def assert_historical_policy_coverage!(provider_scope)
      historical = provider_scope.where(stream: Ingestion::HistoricalBalances::SourceBinding::STREAMS)
      valid = <<~SQL.squish
        source_binding->>'format' = 'historical-command/v1'
        AND source_binding ?& ARRAY['balance_policy_version', 'anchor_policy_version', 'source_batch_id']
        AND jsonb_typeof(source_binding->'source_batch_id') = 'string'
        AND source_binding->>'source_batch_id' ~* '^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$'
        AND (source_binding->'balance_policy_version' = 'null'::jsonb OR
          (jsonb_typeof(source_binding->'balance_policy_version') = 'string'
            AND source_binding->>'balance_policy_version' ~* '^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$'))
        AND (source_binding->'anchor_policy_version' = 'null'::jsonb OR
          (jsonb_typeof(source_binding->'anchor_policy_version') = 'string'
            AND source_binding->>'anchor_policy_version' = source_binding->>'balance_policy_version'
            AND stream = 'opening_anchor_repairs'))
      SQL
      if historical.where("NOT COALESCE((#{valid}), FALSE)").exists?
        raise Incomplete, "Historical command routing is malformed or incomplete"
      end
      reference_join = <<~SQL.squish
        CROSS JOIN LATERAL (VALUES
          (source_binding->>'balance_policy_version'),
          (source_binding->>'anchor_policy_version')) AS captured_policies(policy_id)
      SQL
      missing_policy = <<~SQL.squish
        NOT EXISTS (SELECT 1 FROM account_source_policies secondary_policy
          WHERE secondary_policy.id::text = captured_policies.policy_id
            AND secondary_policy.family_id = ingestion_batches.family_id
            AND secondary_policy.account_id::text = source_binding->>'account_id'
            AND secondary_policy.resource = 'balances')
      SQL
      orphaned = historical.joins(reference_join).where("captured_policies.policy_id IS NOT NULL").where(missing_policy)
      raise Incomplete, "Historical command secondary policy ownership is unresolved" if orphaned.exists?
    end

    def discover_accounts!
      require_rows("accounts", @account_ids.to_a)
      add("account_identities", Account::IngestionIdentity.where(id: @account_ids.to_a))
      add("links", AccountProvider.where(account_id: @account_ids.to_a))
      add("policies", Account::SourcePolicy.where(account_id: @account_ids.to_a))
      add("holdings", Holding.where(account_id: @account_ids.to_a))
      live_policies = rows("policies").select { |policy| policy["active"] || policy["source_binding"].blank? }
      require_rows("links", live_policies.map { |policy| policy["account_provider_id"] } + values("holdings", "account_provider_id"))
      # A captured, inactive revision can outlive its link. Read a remaining link
      # when present, but never substitute it for the revision's selected owner.
      add("links", AccountProvider.where(id: values("policies", "account_provider_id")))
      add_account_ids(values("links", "account_id") + values("policies", "account_id"))
      add("retained_bindings", ProviderMigrationAccountBinding.where(financial_account_id: @account_ids.to_a))
      require_rows("mappings", values("retained_bindings", "provider_migration_mapping_id"))
      add("generations", ProviderSyncGeneration.where("account_ids && ARRAY[?]::uuid[]", @account_ids.to_a))
    end

    def discover_evidence!
      entry_scope = EntrySource.where(account_id: @account_ids.to_a)
        .or(EntrySource.where(entry_id: @effects.affected_entry_ids))
        .or(EntrySource.where(entry_identity: @effects.affected_entry_ids))
      add("entry_sources", entry_scope)
      holding_scope = HoldingSource.where(account_id: @account_ids.to_a)
        .or(HoldingSource.where(holding_id: ids("holdings")))
        .or(HoldingSource.where(holding_identity: ids("holdings")))
      add("holding_sources", holding_scope)
      add("source_records", SourceRecord.where(account_id: @account_ids.to_a))
      require_rows("source_records", values("entry_sources", "source_record_id") + values("holding_sources", "source_record_id"))
      add_account_ids(values("source_records", "account_id") + values("entry_sources", "account_id") + values("holding_sources", "account_id"))
      require_rows("entries", values("entry_sources", "entry_id"))
      require_rows("holdings", values("holding_sources", "holding_id"))
      # Missing historical financial rows are legitimate. If the UUID still
      # exists, however, its account must agree even when the live FK is nil.
      add("entries", Entry.where(id: values("entry_sources", "entry_identity")))
      add("holdings", Holding.where(id: values("holding_sources", "holding_identity")))
    end

    def discover_documents!
      add("import_mappings", Import::Mapping.where(mappable_type: "Account", mappable_id: @account_ids.to_a))
      add("imports", Import.where(account_id: @account_ids.to_a))
      require_rows("imports", values("accounts", "import_id") + values("entries", "import_id") +
        values("import_mappings", "import_id") + values("batches", "import_id"))
      add("documents", AccountStatement.where(account_id: @account_ids.to_a)
        .or(AccountStatement.where(suggested_account_id: @account_ids.to_a)))
      require_rows("documents", values("entries", "reconciled_by_statement_id") + values("imports", "account_statement_id") +
        values("source_records", "account_statement_id") + values("batches", "account_statement_id"))
      add("imports", Import.where(account_statement_id: ids("documents")))
      add_account_ids(values("imports", "account_id") + values("documents", "account_id") + values("documents", "suggested_account_id"))
    end

    def discover_batches!
      scope = IngestionBatch.where("source_binding->>'account_id' IN (?)", @account_ids.to_a)
        .or(IngestionBatch.where(source_policy_version: ids("policies")))
        .or(IngestionBatch.where(origin_kind: "provider", stream: Ingestion::HistoricalBalances::SourceBinding::STREAMS)
          .where("source_binding->>'balance_policy_version' IN (?)", ids("policies")))
        .or(IngestionBatch.where(origin_kind: "provider", stream: Ingestion::HistoricalBalances::SourceBinding::STREAMS)
          .where("source_binding->>'anchor_policy_version' IN (?)", ids("policies")))
        .or(IngestionBatch.where(import_id: ids("imports")))
        .or(IngestionBatch.where(account_statement_id: ids("documents")))
      add("batches", scope)
      require_rows("batches", values("source_records", "ingestion_batch_id") + values("entry_sources", "bootstrap_batch_id") +
        values("retained_bindings", "first_batch_id") + values("sync_inputs", "source_batch_id") + values("batches", "binding_source_batch_id"))
      require_rows("generations", values("batches", "provider_sync_generation_id"))
      require_rows("policies", values("batches", "source_policy_version") + values("batches", "binding_balance_policy_version") + values("batches", "binding_anchor_policy_version"))
      add_account_ids(values("policies", "account_id"))
    end

    def discover_syncs!
      add("syncs", Sync.where(syncable_type: "Account", syncable_id: @account_ids.to_a))
      require_rows("syncs", values("batches", "sync_id") + values("generations", "sync_id") +
        values("sync_inputs", "sync_id") + values("sync_inputs", "provider_sync_id"))
      @deleted_sync_ids.merge(rows("syncs").select { |row| row["syncable_type"] == "Account" && row["syncable_id"] == @root_id }.map { |row| row["id"] })
      settled = false
      (MAX_SYNC_DEPTH + 1).times do
        previous = [ ids("syncs").size, @deleted_sync_ids.size ]
        descendants = Sync.where(parent_id: @deleted_sync_ids.to_a).or(Sync.where(predecessor_id: @deleted_sync_ids.to_a))
        add("syncs", descendants)
        @deleted_sync_ids.merge(rows("syncs").select do |row|
          @deleted_sync_ids.include?(row["parent_id"]) || @deleted_sync_ids.include?(row["predecessor_id"])
        end.map { |row| row["id"] })
        require_rows("syncs", values("syncs", "parent_id") + values("syncs", "predecessor_id"))
        if previous == [ ids("syncs").size, @deleted_sync_ids.size ]
          settled = true
          break
        end
      end
      raise TooLarge, "Account source sync graph exceeds its traversal bound" unless settled
      validate_sync_graph!
      account_syncs = rows("syncs").select { |row| row["syncable_type"] == "Account" }
      add_account_ids(account_syncs.map { |row| row["syncable_id"] })
      add("sync_inputs", Account::SyncInput.where(account_id: @account_ids.to_a).or(Account::SyncInput.where(sync_id: ids("syncs"))))
      add("sync_sources", Account::SyncSource.where(account_id: @account_ids.to_a)
        .or(Account::SyncSource.where(account_sync_input_id: ids("sync_inputs"))))
      require_rows("sync_inputs", values("sync_sources", "account_sync_input_id"))
      add_account_ids(values("sync_inputs", "account_id") + values("sync_sources", "account_id"))
      add("sync_preparations", Account::SyncPreparation.where(sync_id: ids("syncs")))
    end

    def validate_sync_graph!
      visiting, heights = Set.new, {}
      visit = lambda do |id, depth|
        raise TooLarge, "Account source sync graph exceeds its depth bound" if depth > MAX_SYNC_DEPTH
        if heights.key?(id)
          raise TooLarge, "Account source sync graph exceeds its depth bound" if depth + heights[id] > MAX_SYNC_DEPTH
          next heights[id]
        end
        raise InvalidGraph, "Account source sync graph contains a cycle" unless visiting.add?(id)
        row = @rows.fetch("syncs")[id]
        raise InvalidGraph, "Account source sync ancestor is missing" unless row
        height = [ row["parent_id"], row["predecessor_id"] ].compact.map { |parent| visit.call(parent, depth + 1) + 1 }.max || 0
        visiting.delete(id)
        heights[id] = height
      end
      ids("syncs").each { |id| visit.call(id, 0) }
      rows("syncs").each do |row|
        case row["syncable_type"]
        when "Account"
          raise InvalidGraph, "Account source sync has no owner identity" unless row["syncable_id"].to_s.match?(UUID)
          raise Incomplete, "Account source sync has no captured family" unless row["account_family_id"]
          raise InvalidGraph, "Account source sync belongs to another family" unless row["account_family_id"] == @family_id
        when "ProviderConnection"
          raise InvalidGraph, "Account source sync has no owner identity" unless row["syncable_id"].to_s.match?(UUID)
        when "Family"
          raise InvalidGraph, "Account source sync belongs to another family" unless row["syncable_id"] == @family_id
        else
          raise InvalidGraph, "Account source sync has an unsupported owner" unless @item_types.include?(row["syncable_type"])
        end
      end
    end

    def validate_references!
      rows("account_identities").each do |identity|
        unless identity["live_account_id"] == identity["id"] && identity["retired_at"].nil? && ids("accounts").include?(identity["id"])
          raise Incomplete, "Retired account ownership requires lifecycle disposition"
        end
      end
      rows("source_records").each do |source|
        if source["account_id"] && !@rows.fetch("account_identities").key?(source["account_id"])
          raise Incomplete, "Published source record has no retained account identity"
        end
      end
      unless rows("import_mappings").all? { |row| row["type"] == "Import::AccountMapping" && row["mappable_type"] == "Account" }
        raise InvalidGraph, "Account import mapping has an unsupported type"
      end
      rows("policies").each do |policy|
        unless @rows.fetch("account_identities").key?(policy["account_id"])
          raise Incomplete, "Source policy has no retained account identity"
        end
        if policy["source_binding"].blank?
          raise Incomplete, "Source policy has no captured original owner"
        end
        begin
          Account::SourcePolicy::Binding.validate!(policy["source_binding"], policy: policy)
        rescue Account::SourcePolicy::Binding::Conflict
          raise InvalidGraph, "Source policy has an inconsistent captured owner", cause: nil
        end
        link = @rows.fetch("links")[policy.fetch("account_provider_id")]
        if link && (link["account_id"] != policy["account_id"] || link["family_id"] != @family_id)
          raise InvalidGraph, "Captured policy has a different financial owner"
        end
      end
      rows("holdings").each do |holding|
        next unless holding["account_provider_id"]
        link = @rows.fetch("links").fetch(holding.fetch("account_provider_id"))
        raise InvalidGraph, "Holding provider belongs to another financial account" unless link["account_id"] == holding["account_id"]
      end
      %w[entry_sources holding_sources].each do |kind|
        rows(kind).each do |evidence|
          source = @rows.fetch("source_records").fetch(evidence.fetch("source_record_id"))
          raise InvalidGraph, "Financial evidence has a different source owner" unless source["account_id"] == evidence["account_id"]
          live_key, table, identity = kind == "entry_sources" ? %w[entry_id entries entry_identity] : %w[holding_id holdings holding_identity]
          target = evidence[live_key] && @rows.fetch(table).fetch(evidence[live_key])
          historical = @rows.fetch(table)[evidence[identity]]
          if [ target, historical ].compact.any? { |row| row["account_id"] != evidence["account_id"] }
            raise InvalidGraph, "Financial evidence points to another account"
          end
          if evidence["bootstrap_external_account_id"] && evidence["bootstrap_external_account_id"] != source["external_account_id"]
            raise InvalidGraph, "Bootstrap evidence has a different source account"
          end
          if evidence["bootstrap_batch_id"]
            bootstrap = @rows.fetch("batches").fetch(evidence["bootstrap_batch_id"])
            unless bootstrap["origin_kind"] == "migration" && bootstrap["stream"] == "legacy_financial_identities" &&
                bootstrap["external_account_id"] == evidence["bootstrap_external_account_id"] &&
                bootstrap["scope_key"] == "account:#{evidence['bootstrap_external_account_id']}" &&
                bootstrap["sync_id"].nil? && bootstrap["import_id"].nil? && bootstrap["account_statement_id"].nil? &&
                bootstrap["provider_authorization_id"].nil? && bootstrap["provider_sync_generation_id"].nil?
              raise InvalidGraph, "Bootstrap batch has a different captured origin"
            end
          end
        end
      end
      rows("source_records").each do |source|
        batch = @rows.fetch("batches").fetch(source.fetch("ingestion_batch_id"))
        unless [ source["external_account_id"], source["account_statement_id"] ].compact.one? &&
            source["external_account_id"] == batch["external_account_id"] && source["account_statement_id"] == batch["account_statement_id"]
          raise InvalidGraph, "Source record has a different captured origin"
        end
      end
      rows("batches").each { |batch| validate_batch!(batch) }
      rows("generations").each do |generation|
        sync = @rows.fetch("syncs").fetch(generation.fetch("sync_id"))
        unless sync["syncable_type"] == "ProviderConnection" && sync["syncable_id"] == generation["provider_connection_id"]
          raise InvalidGraph, "Provider generation has a different Sync owner"
        end
      end
      rows("sync_inputs").each do |input|
        sync = @rows.fetch("syncs").fetch(input.fetch("sync_id"))
        batch = @rows.fetch("batches").fetch(input.fetch("source_batch_id"))
        unless sync["syncable_type"] == "Account" && sync["syncable_id"] == input["account_id"] &&
            sync["account_family_id"] == input["family_id"] && batch["sync_id"] == input["provider_sync_id"]
          raise InvalidGraph, "Account calculation has a different captured owner"
        end
      end
      rows("sync_sources").each do |source|
        input = @rows.fetch("sync_inputs").fetch(source.fetch("account_sync_input_id"))
        unless input["account_id"] == source["account_id"] && input["resource"] == source["resource"]
          raise InvalidGraph, "Selected calculation input has a different owner"
        end
      end
    end

    def validate_batch!(batch)
      validate_historical_binding!(batch) if Ingestion::HistoricalBalances::SourceBinding::STREAMS.include?(batch["stream"]) && batch["origin_kind"] == "provider"
      policy = batch["source_policy_version"] && @rows.fetch("policies").fetch(batch["source_policy_version"])
      if batch["binding_captured"]
        unless batch["origin_kind"] == "provider" && batch["binding_external_account_id"] == batch["external_account_id"] &&
            batch["binding_resource"] == batch["stream"] && batch["binding_source_policy_version"] == batch["source_policy_version"] &&
            %w[ledger retained].include?(batch["binding_publication"])
          raise InvalidGraph, "Provider batch account capture is inconsistent"
        end
        if batch["binding_account_id"]
          unless batch["binding_account_id"].match?(UUID) && batch["binding_account_provider_id"].to_s.match?(UUID) &&
              (!policy || policy["account_id"] == batch["binding_account_id"])
            raise InvalidGraph, "Provider batch financial binding is inconsistent"
          end
        elsif batch["binding_account_provider_id"] || policy || batch["binding_publication"] != "retained"
          raise InvalidGraph, "Unlinked batch capture is inconsistent"
        end
      end
      if policy && policy["resource"] != (HISTORICAL_STREAMS.include?(batch["stream"]) ? "historical_balances" : batch["stream"])
        raise InvalidGraph, "Provider batch policy belongs to another resource"
      end
      if batch["origin_kind"] == "file"
        import = @rows.fetch("imports")[batch["import_id"]]
        unless import && import["account_statement_id"] == batch["account_statement_id"] && batch["provider_connection_id"].nil?
          raise InvalidGraph, "Document batch has a different import owner"
        end
      elsif !%w[provider migration].include?(batch["origin_kind"]) || batch["provider_connection_id"].nil?
        raise InvalidGraph, "Provider batch has no supported connection owner"
      end
      if batch["origin_kind"] == "provider"
        sync = @rows.fetch("syncs")[batch["sync_id"]]
        unless sync && sync["syncable_type"] == "ProviderConnection" && sync["syncable_id"] == batch["provider_connection_id"]
          raise InvalidGraph, "Provider batch has a different Sync owner"
        end
      end
      if batch["provider_sync_generation_id"]
        generation = @rows.fetch("generations").fetch(batch["provider_sync_generation_id"])
        unless batch["provider_connection_id"] == generation["provider_connection_id"] && batch["sync_id"] == generation["sync_id"] &&
            batch["writer_epoch"] == generation["writer_epoch"] && batch["generation_resource"] == generation["stream"]
          raise InvalidGraph, "Provider batch has a different generation owner"
        end
      end
    end

    def validate_historical_binding!(batch)
      unless batch["binding_format"] == Ingestion::HistoricalBalances::SourceBinding::FORMAT && batch["binding_captured"]
        raise Incomplete, "Historical command has no indexed original binding"
      end
      %w[binding_balance_policy_version binding_anchor_policy_version].each do |key|
        next unless batch[key]
        policy = @rows.fetch("policies").fetch(batch[key])
        unless policy["resource"] == "balances" && policy["account_id"] == batch["binding_account_id"]
          raise InvalidGraph, "Historical command has a different secondary policy owner"
        end
      end
      source = @rows.fetch("batches").fetch(batch["binding_source_batch_id"])
      unless source["origin_kind"] == "provider" && source["stream"] == "equity_snapshots" &&
          %w[provider_connection_id external_account_id sync_id writer_epoch source_policy_version].all? { |key| source[key] == batch[key] }
        raise InvalidGraph, "Historical command has a different source batch owner"
      end
    end

    def resolve_owners!
      direct = rows("accounts").flat_map do |account|
        { "plaid_account_id" => "PlaidAccount", "simplefin_account_id" => "SimplefinAccount" }.filter_map do |column, type|
          { "account_id" => account["id"], "provider_type" => type, "provider_id" => account[column] } if account[column]
        end
      end
      legacy = rows("syncs").select { |row| @item_types.include?(row["syncable_type"]) }
        .map { |row| { "type" => row["syncable_type"], "id" => row["syncable_id"] } }.uniq
      connection_ids = values("batches", "provider_connection_id") + values("generations", "provider_connection_id") +
        rows("syncs").select { |row| row["syncable_type"] == "ProviderConnection" }.map { |row| row["syncable_id"] }
      external_ids = values("links", "external_account_id") + values("mappings", "external_account_id") +
        values("batches", "external_account_id") + values("source_records", "external_account_id") + values("entry_sources", "bootstrap_external_account_id")
      retained = rows("policies").map { |policy| { "policy_id" => policy.fetch("id"), "binding" => policy.fetch("source_binding") } }
      Ingestion::SourceOwners.capture(family_id: @family_id, links: rows("links"), direct_sources: direct,
        external_ids: external_ids.uniq, connection_ids: connection_ids.uniq, legacy_items: legacy, retained_sources: retained)
    end

    def validate_owner_references!(owners)
      external_by_id = owners.proof.fetch("external_accounts").index_by { |row| row.fetch("id") }
      rows("batches").each do |batch|
        next unless batch["external_account_id"]
        external = external_by_id.fetch(batch["external_account_id"])
        unless external["provider_connection_id"] == batch["provider_connection_id"]
          raise InvalidGraph, "Provider batch and external account have different connection owners"
        end
      end
    end

    def snapshot(owners)
      proof = { "format" => FORMAT, "effects" => @effects.proof, "owners" => owners.proof,
        "deleted_sync_ids" => @deleted_sync_ids.to_a.sort }
      @rows.each { |kind, indexed| proof[kind] = indexed.values.sort_by { |row| row.fetch("id") } }
      Snapshot.new(**deep_freeze({ family_id: @family_id, root_account_id: @root_id, account_ids: @account_ids.to_a.sort,
        legacy_items: owners.legacy_items, legacy_accounts: owners.legacy_accounts, connection_ids: owners.connection_ids,
        external_ids: owners.external_ids, control_ids: owners.control_ids, mapping_ids: owners.mapping_ids,
        document_ids: ids("documents").sort, import_ids: ids("imports").sort, proof: proof }))
    end

    def deep_freeze(value)
      case value
      when Hash then value.each { |key, item| deep_freeze(key); deep_freeze(item) }
      when Array then value.each { |item| deep_freeze(item) }
      end
      value.freeze
    end
end
