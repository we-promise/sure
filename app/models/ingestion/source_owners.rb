require "set"

# Resolves selected source identities, not deletion permission. Native, legacy,
# and dual ownership all remain visible. The caller discovers references and must
# separately admit/lock owners and compare a fresh inventory before any mutation.
class Ingestion::SourceOwners
  MAX_OWNERS = 1_000
  MAX_ROWS = 10_000
  MAX_RETAINED_BINDING_BYTES = 16_384
  MAX_RETIRED_ARCHIVE_BYTES = 32 * 1024 * 1024
  FORMAT = "account-destruction-source-owners/v1".freeze
  UUID = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/
  LINK_COLUMNS = %w[id account_id provider_type provider_id external_account_id family_id provider_key lock_version].freeze
  DIRECT_COLUMNS = { "PlaidAccount" => "plaid_account_id", "SimplefinAccount" => "simplefin_account_id" }.freeze
  CONTROL_COLUMNS = %w[id family_id provider_key legacy_type legacy_id provider_connection_id state writer_epoch copy_version].freeze
  MAPPING_COLUMNS = %w[id family_id provider_migration_control_id legacy_type legacy_id role provider_connection_id provider_authorization_id external_account_id].freeze
  RETAINED_COLUMNS = %w[id account_id family_id account_provider_id source_binding].freeze

  class InvalidGraph < StandardError; end
  class TooLarge < InvalidGraph; end
  class DispositionRequired < InvalidGraph; end

  Snapshot = Data.define(:proof, :legacy_items, :legacy_accounts, :connection_ids, :external_ids, :control_ids, :mapping_ids)

  def self.capture(family_id:, links:, direct_sources:, external_ids:, legacy_items: [], connection_ids: [], retained_sources: [])
    new(family_id).capture(links: links, direct_sources: direct_sources, external_ids: external_ids,
      legacy_items: legacy_items, connection_ids: connection_ids, retained_sources: retained_sources)
  end

  def initialize(family_id)
    raise InvalidGraph, "Expected a financial family identity" unless uuid?(family_id)
    @family_id = family_id.dup
    manifests = Provider::AccountData::MigrationManifest.all
    @account_manifests = manifests.index_by(&:account_type)
    @item_manifests = manifests.index_by(&:item_type)
    @rows = %w[accounts links legacy_accounts legacy_items external_accounts connections controls mappings].to_h { |key| [ key, {} ] }
    @pending = []
    @owners = Set.new
    @known_keys = Set.new
    @claims = {}
    @direct_links = {}
    @retained_legacy = {}
    @retained_items = Set.new
    @retained_links = {}
    @row_count = 0
    @retired_archive_bytes = 0
  end

  def capture(links:, direct_sources:, external_ids:, legacy_items:, connection_ids:, retained_sources: [])
    ApplicationRecord.uncached do
      capture_links!(bounded_array!(links))
      direct = bounded_array!(direct_sources).map { |value| normalize!(value, %w[account_id provider_type provider_id]) }
      direct.each { |source| capture_direct!(source) }
      capture_retained_sources!(bounded_array!(retained_sources))
      bounded_array!(external_ids).each { |id| enqueue("external_accounts", id) }
      bounded_array!(connection_ids).each { |id| enqueue("connections", id) }
      bounded_array!(legacy_items).each do |value|
        item = normalize!(value, %w[type id])
        manifest_for_item!(item.fetch("type"))
        enqueue("legacy_items", item.fetch("id"), item.fetch("type"))
      end
      until @pending.empty?
        kind, type, id = @pending.shift
        case kind
        when "legacy_accounts" then resolve_legacy_account!(type, id)
        when "legacy_items" then resolve_legacy_item!(type, id)
        when "external_accounts" then resolve_external!(id)
        when "connections" then resolve_connection!(id)
        end
      end
      verify_mappings!
      verify_links!(direct)
      verify_retained_sources!
      snapshot
    end
  end

  private
    def uuid?(value) = value.is_a?(String) && value.match?(UUID)

    def bounded_array!(value)
      raise InvalidGraph, "Source owner references must be an array" unless value.is_a?(Array)
      raise TooLarge, "Source owner references exceed their row bound" if value.size > MAX_ROWS
      value
    end

    def normalize!(value, columns)
      unless value.is_a?(Hash) && value.keys.all? { |key| key.is_a?(String) || key.is_a?(Symbol) }
        raise InvalidGraph, "Source owner reference is malformed"
      end
      normalized = value.transform_keys(&:to_s)
      unless normalized.size == value.size && columns.all? { |column| normalized.key?(column) }
        raise InvalidGraph, "Source owner reference is incomplete"
      end
      normalized.slice(*columns)
    end

    def read(model, scope, columns)
      table = model.connection.quote_table_name(model.table_name)
      values = scope.reorder(:id).limit(MAX_ROWS + 1).pluck(*columns,
        Arel.sql("#{table}.xmin::text"), Arel.sql("#{table}.ctid::text"))
      raise TooLarge, "Source owner inventory exceeds its row bound" if values.size > MAX_ROWS
      values.map { |row| (columns + %w[row_version tuple_version]).zip(row).to_h }
    end

    def remember!(kind, row, key: row.fetch("id"))
      previous = @rows.fetch(kind)[key]
      raise InvalidGraph, "Source ownership changed during capture" if previous && previous != row
      return if previous
      @row_count += 1
      raise TooLarge, "Source owner inventory exceeds its row bound" if @row_count > MAX_ROWS
      @rows.fetch(kind)[key] = row
    end

    def enqueue(kind, id, type = nil)
      raise InvalidGraph, "Source owner identity is invalid" unless uuid?(id)
      key = [ kind, type, id ]
      return unless @owners.add?(key)
      raise TooLarge, "Source owner inventory exceeds its owner bound" if @owners.size > MAX_OWNERS
      @pending << key
    end

    def sole_or_nil!(rows)
      raise InvalidGraph, "Source owner identity is ambiguous" if rows.size > 1
      rows.first
    end

    def manifest_for_account!(type)
      @account_manifests.fetch(type) { raise InvalidGraph, "Unregistered legacy account owner" }
    end

    def manifest_for_item!(type)
      @item_manifests.fetch(type) { raise InvalidGraph, "Unregistered legacy item owner" }
    end

    def financial!(id)
      raise InvalidGraph, "Financial owner identity is invalid" unless uuid?(id)
      return @rows.fetch("accounts").fetch(id) if @rows.fetch("accounts").key?(id)
      row = read(Account, Account.where(id: id), %w[id family_id plaid_account_id simplefin_account_id]).first
      raise InvalidGraph, "Financial source owner is missing or belongs to another family" unless row && row["family_id"] == @family_id
      remember!("accounts", row)
      row
    end

    def claim!(type, id, account_id)
      manifest_for_account!(type)
      raise InvalidGraph, "Legacy account identity is invalid" unless uuid?(id)
      key = [ type, id ]
      if @claims[key] && @claims[key] != account_id
        raise InvalidGraph, "Legacy source has conflicting financial owners"
      end
      @claims[key] = account_id
      enqueue("legacy_accounts", id, type)
    end

    def capture_links!(values)
      expected = values.map { |value| normalize!(value, LINK_COLUMNS) }
      ids = expected.map { |row| row["id"] }
      unless ids.all? { |id| uuid?(id) } && ids.uniq.size == ids.size
        raise InvalidGraph, "Selected provider links are invalid or duplicated"
      end
      actual = read(AccountProvider, AccountProvider.where(id: ids), LINK_COLUMNS)
      by_id = actual.index_by { |row| row.fetch("id") }
      unless actual.size == ids.size && expected.all? { |row| by_id.fetch(row.fetch("id")).slice(*LINK_COLUMNS) == row }
        raise InvalidGraph, "Selected provider link changed or disappeared"
      end
      actual.each { |link| capture_link!(link) }
    end

    def capture_link!(link)
      financial!(link.fetch("account_id"))
      legacy = !link["provider_type"].nil? || !link["provider_id"].nil?
      shared = !link["external_account_id"].nil?
      raise InvalidGraph, "Provider link has no source owner" unless legacy || shared
      if legacy
        manifest = manifest_for_account!(link["provider_type"])
        unless (link["family_id"].nil? || link["family_id"] == @family_id) &&
            (link["provider_key"].nil? || link["provider_key"] == manifest.provider_key)
          raise InvalidGraph, "Legacy provider link belongs to another owner"
        end
        claim!(link["provider_type"], link["provider_id"], link["account_id"])
      end
      if shared
        raise InvalidGraph, "Shared provider link has inconsistent family ownership" unless link["family_id"] == @family_id
        enqueue("external_accounts", link["external_account_id"])
      end
      remember!("links", link)
    end

    def capture_direct!(source)
      type, id, account_id = source.values_at("provider_type", "provider_id", "account_id")
      column = DIRECT_COLUMNS[type]
      unless column && financial!(account_id)[column] == id
        raise InvalidGraph, "Direct legacy source no longer belongs to its financial account"
      end
      claim!(type, id, account_id)
      manifest = manifest_for_account!(type)
      links = direct_links_for(source, manifest)
      @direct_links[[ account_id, type ]] = links.map { |link| link.fetch("id") }
      links.each { |link| capture_link!(link) }
    end

    def capture_retained_sources!(values)
      return if values.empty?
      expected = values.map { |value| normalize!(value, %w[policy_id binding]) }
      ids = expected.map { |row| row["policy_id"] }
      unless ids.all? { |id| uuid?(id) } && ids.uniq.size == ids.size
        raise InvalidGraph, "Retained source policy references are invalid or duplicated"
      end
      scope = Account::SourcePolicy.where(id: ids)
      if scope.where("octet_length(source_binding::text) > ?", MAX_RETAINED_BINDING_BYTES).exists?
        raise TooLarge, "Retained source policy binding exceeds its byte bound"
      end
      # Keep the size predicate on the materializing query too: a separate
      # preflight alone cannot bound a concurrently changed historical row.
      actual = read(Account::SourcePolicy,
        scope.where("octet_length(source_binding::text) <= ?", MAX_RETAINED_BINDING_BYTES), RETAINED_COLUMNS)
      by_id = actual.index_by { |row| row.fetch("id") }
      unless actual.size == ids.size && expected.all? { |row| by_id.fetch(row.fetch("policy_id"))["source_binding"] == row["binding"] }
        raise InvalidGraph, "Retained source policy changed or disappeared"
      end
      @rows["retained_sources"] = {}
      actual.each do |row|
        raise InvalidGraph, "Retained source policy belongs to another family" unless row["family_id"] == @family_id
        binding = row.fetch("source_binding")
        Account::SourcePolicy::Binding.validate!(binding, policy: row)
        remember!("retained_sources", row)
        retain_link_tuple!(binding)
        if binding["legacy_account_id"]
          key = binding.values_at("legacy_account_type", "legacy_account_id")
          origin = binding.slice("legacy_item_type", "legacy_item_id", "provider_key")
          if @retained_legacy[key] && @retained_legacy[key] != origin
            raise InvalidGraph, "Retained legacy source has conflicting original owners"
          end
          @retained_legacy[key] = origin
          @retained_items.add(binding.values_at("legacy_item_type", "legacy_item_id"))
          enqueue("legacy_accounts", binding.fetch("legacy_account_id"), binding.fetch("legacy_account_type"))
          enqueue("legacy_items", binding.fetch("legacy_item_id"), binding.fetch("legacy_item_type"))
        end
        if binding["external_account_id"]
          enqueue("external_accounts", binding.fetch("external_account_id"))
          enqueue("connections", binding.fetch("provider_connection_id"))
        end
      end
    rescue Account::SourcePolicy::Binding::Conflict
      raise InvalidGraph, "Retained source policy has no valid captured owner", cause: nil
    end

    def retain_link_tuple!(binding)
      key = binding.fetch("account_provider_id")
      original = @retained_links[key]
      stable = %w[account_id family_id account_provider_id provider_key legacy_account_type legacy_account_id legacy_item_type legacy_item_id]
      shared = %w[external_account_id provider_connection_id]
      if original && (original.slice(*stable) != binding.slice(*stable) ||
          (original["external_account_id"] && binding["external_account_id"] && original.slice(*shared) != binding.slice(*shared)))
        raise InvalidGraph, "Retained provider link has conflicting original source identities"
      end
      @retained_links[key] = binding if original.nil? || binding["external_account_id"]
    end

    def resolve_legacy_account!(type, id)
      manifest = manifest_for_account!(type)
      mapping = sole_or_nil!(read(ProviderMigrationMapping,
        ProviderMigrationMapping.where(legacy_type: type, legacy_id: id, role: "external_account"), MAPPING_COLUMNS))
      add_mapping!(mapping) if mapping
      model = manifest.account_type.constantize # Only a reviewed manifest supplies this class.
      row = read(model, model.where(id: id), [ "id", manifest.account_foreign_key ]).first
      retained = @retained_legacy[[ type, id ]]
      if row.nil?
        if mapping && @rows.fetch("controls").fetch(mapping.fetch("provider_migration_control_id"))["state"] == "retired"
          owner = retired_owner!(mapping)
          if retained && owner.fetch("item_id") != retained.fetch("legacy_item_id")
            raise InvalidGraph, "Retired source parent differs from its retained original owner"
          end
          remember!("legacy_accounts", owner, key: [ type, id ])
          enqueue("legacy_items", owner.fetch("item_id"), manifest.item_type)
          verify_financial_claim!(manifest, id) if @claims.key?([ type, id ])
          return
        end
        if retained && !@claims.key?([ type, id ])
          # This is an original policy witness, never a current financial link
          # or a reconstructed legacy model. The parent item still must resolve.
          remember!("legacy_accounts", { "id" => id, "type" => type, "item_id" => retained.fetch("legacy_item_id"),
            "retained_missing" => true, "row_version" => nil, "tuple_version" => nil }, key: [ type, id ])
          return
        end
        raise DispositionRequired, "Retained legacy account is missing; explicit retirement disposition is required" if mapping
        raise InvalidGraph, "Legacy account owner is missing"
      end
      item_id = row.delete(manifest.account_foreign_key)
      if retained && item_id != retained.fetch("legacy_item_id")
        raise InvalidGraph, "Legacy source parent differs from its retained original owner"
      end
      row.merge!("type" => type, "item_id" => item_id)
      remember!("legacy_accounts", row, key: [ type, id ])
      enqueue("legacy_items", item_id, manifest.item_type)
      verify_financial_claim!(manifest, id) if @claims.key?([ type, id ])
    end

    def verify_financial_claim!(manifest, source_id)
      account_id = @claims.fetch([ manifest.account_type, source_id ])
      links = read(AccountProvider, AccountProvider.where(provider_type: manifest.account_type, provider_id: source_id), LINK_COLUMNS)
      unless links.all? { |link| link["account_id"] == account_id } && links.size <= 1
        raise InvalidGraph, "Legacy source has another provider-link owner"
      end
      links.each { |link| capture_link!(link) }
      column = DIRECT_COLUMNS[manifest.account_type]
      return unless column
      own_direct_id = financial!(account_id)[column]
      if own_direct_id && own_direct_id != source_id
        raise InvalidGraph, "Direct and provider-link source identities disagree"
      end
      owners = read(Account, Account.where(column => source_id), %w[id family_id plaid_account_id simplefin_account_id])
      unless owners.all? { |row| row["id"] == account_id && row["family_id"] == @family_id }
        raise InvalidGraph, "Legacy source has another direct financial owner"
      end
      owners.each { |row| remember!("accounts", row) }
    end

    def resolve_legacy_item!(type, id)
      manifest = manifest_for_item!(type)
      control = sole_or_nil!(read(ProviderMigrationControl,
        ProviderMigrationControl.where(legacy_type: type, legacy_id: id), CONTROL_COLUMNS))
      add_control!(control) if control
      model = manifest.item_type.constantize
      row = read(model, model.where(id: id), %w[id family_id]).first
      if row.nil?
        if control && control["state"] == "retired"
          mapping = sole_or_nil!(read(ProviderMigrationMapping,
            ProviderMigrationMapping.where(provider_migration_control_id: control.fetch("id"), role: "connection"), MAPPING_COLUMNS))
          if mapping
            add_mapping!(mapping)
            remember!("legacy_items", retired_owner!(mapping), key: [ type, id ])
            return
          end
        end
        if control || @retained_items.include?([ type, id ])
          raise DispositionRequired, "Retained legacy item is missing; explicit retirement disposition is required"
        end
        raise InvalidGraph, "Legacy item owner is missing"
      end
      raise InvalidGraph, "Legacy item belongs to another family" unless row["family_id"] == @family_id
      row["type"] = type
      remember!("legacy_items", row, key: [ type, id ])
    end

    def retired_owner!(mapping)
      remaining = MAX_RETIRED_ARCHIVE_BYTES - @retired_archive_bytes
      raise TooLarge, "Retired source archives exceed their cumulative read bound" unless remaining.positive?
      resolved = Provider::AccountData::RetiredOwner.resolve!(
        mapping: ProviderMigrationMapping.find(mapping.fetch("id")), family_id: @family_id, max_bytes: remaining)
      @retired_archive_bytes += resolved.bytes
      raise TooLarge, "Retired source archives exceed their cumulative read bound" if @retired_archive_bytes > MAX_RETIRED_ARCHIVE_BYTES
      resolved.owner
    rescue Provider::AccountData::RetiredOwner::TooLarge
      raise TooLarge, "Retired source archives exceed their cumulative read bound", cause: nil
    rescue Provider::AccountData::RetiredOwner::Conflict, ActiveRecord::RecordNotFound
      raise DispositionRequired, "Retired source ownership has no verified archive disposition", cause: nil
    end

    def resolve_external!(id)
      row = read(ExternalAccount, ExternalAccount.where(id: id), %w[id family_id provider_connection_id provider_key identity_namespace]).first
      raise InvalidGraph, "External account is missing or belongs to another family" unless row && row["family_id"] == @family_id
      remember!("external_accounts", row)
      enqueue("connections", row["provider_connection_id"])
      mapping = sole_or_nil!(read(ProviderMigrationMapping, ProviderMigrationMapping.where(external_account_id: id), MAPPING_COLUMNS))
      add_mapping!(mapping) if mapping
    end

    def resolve_connection!(id)
      row = read(ProviderConnection, ProviderConnection.where(id: id), %w[id family_id provider_key]).first
      raise InvalidGraph, "Provider connection is missing or belongs to another family" unless row && row["family_id"] == @family_id
      unless @known_keys.include?(row["provider_key"])
        Provider::AccountData::Registry.declared_adapter(row["provider_key"])
        @known_keys.add(row["provider_key"])
      end
      remember!("connections", row)
      control = sole_or_nil!(read(ProviderMigrationControl, ProviderMigrationControl.where(provider_connection_id: id), CONTROL_COLUMNS))
      add_control!(control) if control
      mapping = sole_or_nil!(read(ProviderMigrationMapping, ProviderMigrationMapping.where(provider_connection_id: id), MAPPING_COLUMNS))
      add_mapping!(mapping) if mapping
    rescue Provider::AccountData::UnsupportedCapability
      raise InvalidGraph, "Unregistered native provider owner", cause: nil
    end

    def add_control!(row)
      manifest = manifest_for_item!(row["legacy_type"])
      unless row["family_id"] == @family_id && row["provider_key"] == manifest.provider_key
        raise InvalidGraph, "Provider migration control has inconsistent ownership"
      end
      remember!("controls", row)
      enqueue("legacy_items", row["legacy_id"], row["legacy_type"])
      enqueue("connections", row["provider_connection_id"]) if row["provider_connection_id"]
    end

    def add_mapping!(row)
      unless row["family_id"] == @family_id && %w[connection external_account].include?(row["role"]) &&
          row["provider_authorization_id"].nil? &&
          (row["role"] == "connection" ? row["provider_connection_id"].present? && row["external_account_id"].nil? :
            row["external_account_id"].present? && row["provider_connection_id"].nil?)
        raise InvalidGraph, "Provider migration mapping has inconsistent ownership"
      end
      remember!("mappings", row)
      control = read(ProviderMigrationControl, ProviderMigrationControl.where(id: row["provider_migration_control_id"]), CONTROL_COLUMNS).first
      raise InvalidGraph, "Provider migration mapping lost its control" unless control
      add_control!(control)
      if row["role"] == "connection"
        manifest_for_item!(row["legacy_type"])
        enqueue("legacy_items", row["legacy_id"], row["legacy_type"])
        enqueue("connections", row["provider_connection_id"])
      else
        manifest_for_account!(row["legacy_type"])
        enqueue("legacy_accounts", row["legacy_id"], row["legacy_type"])
        enqueue("external_accounts", row["external_account_id"])
      end
    end

    def verify_mappings!
      @rows.fetch("external_accounts").each_value do |external|
        connection = @rows.fetch("connections").fetch(external.fetch("provider_connection_id"))
        raise InvalidGraph, "External account provider identity differs from its connection" unless external["provider_key"] == connection["provider_key"]
      end
      @rows.fetch("controls").each_value do |control|
        next unless control["provider_connection_id"]
        connection = @rows.fetch("connections").fetch(control["provider_connection_id"])
        raise InvalidGraph, "Migration control provider identity differs from its connection" unless control["provider_key"] == connection["provider_key"]
      end
      @rows.fetch("mappings").each_value do |mapping|
        control = @rows.fetch("controls").fetch(mapping["provider_migration_control_id"])
        if mapping["role"] == "connection"
          valid = mapping["legacy_type"] == control["legacy_type"] && mapping["legacy_id"] == control["legacy_id"] &&
            mapping["provider_connection_id"] == control["provider_connection_id"]
        else
          manifest = manifest_for_account!(mapping["legacy_type"])
          source = @rows.fetch("legacy_accounts").fetch([ mapping["legacy_type"], mapping["legacy_id"] ])
          external = @rows.fetch("external_accounts").fetch(mapping["external_account_id"])
          valid = manifest.item_type == control["legacy_type"] && source["item_id"] == control["legacy_id"] &&
            manifest.provider_key == control["provider_key"] && external["provider_connection_id"] == control["provider_connection_id"]
        end
        raise InvalidGraph, "Migration mapping does not identify the exact legacy owner and target" unless valid
      end
    end

    def verify_links!(direct)
      @rows.fetch("links").each_value do |link|
        next unless link["external_account_id"]
        external = @rows.fetch("external_accounts")[link["external_account_id"]]
        unless external && link["family_id"] == @family_id && link["provider_key"] == external["provider_key"]
          raise InvalidGraph, "Shared provider link has inconsistent ownership"
        end
        verify_dual!(link["provider_type"], link["provider_id"], external["id"]) if link["provider_type"]
      end
      direct.each do |source|
        manifest = manifest_for_account!(source["provider_type"])
        # Inspect only this financial account's corresponding provider claims.
        links = direct_links_for(source, manifest)
        unless links.map { |link| link.fetch("id") } == @direct_links.fetch([ source["account_id"], source["provider_type"] ])
          raise InvalidGraph, "Direct provider link inventory changed during capture"
        end
        links.each do |link|
          if link["provider_type"] && (link["provider_type"] != source["provider_type"] || link["provider_id"] != source["provider_id"])
            raise InvalidGraph, "Direct and provider-link source identities disagree"
          end
          if link["external_account_id"]
            verify_dual!(source["provider_type"], source["provider_id"], link["external_account_id"])
          end
          remember!("links", link)
        end
      end
    end

    def verify_retained_sources!
      return unless @rows.key?("retained_sources")
      @rows.fetch("retained_sources").each_value do |row|
        binding = row.fetch("source_binding")
        if binding["external_account_id"]
          external = @rows.fetch("external_accounts").fetch(binding.fetch("external_account_id"))
          unless external["provider_connection_id"] == binding["provider_connection_id"] && external["provider_key"] == binding["provider_key"]
            raise InvalidGraph, "Retained source differs from its captured shared owner"
          end
          if binding["legacy_account_id"]
            verify_dual!(binding.fetch("legacy_account_type"), binding.fetch("legacy_account_id"), external.fetch("id"))
          end
        end
        # Only compare a live link when the caller independently supplied it.
        # Historical revisions must not claim its financial account is current.
        link = @rows.fetch("links")[binding.fetch("account_provider_id")]
        next unless link
        unless link["account_id"] == binding["account_id"] && (link["family_id"].nil? || link["family_id"] == binding["family_id"]) &&
            link["provider_type"] == binding["legacy_account_type"] && link["provider_id"] == binding["legacy_account_id"] &&
            (link["provider_key"].nil? || link["provider_key"] == binding["provider_key"]) &&
            (binding["external_account_id"].nil? || link["external_account_id"] == binding["external_account_id"])
          raise InvalidGraph, "Current provider link contradicts its retained original source"
        end
      end
      if @rows.fetch("legacy_accounts").any? { |key, row| row["retained_missing"] && @claims.key?(key) }
        raise InvalidGraph, "Retained legacy evidence cannot replace a missing current source"
      end
    end

    def direct_links_for(source, manifest)
      read(AccountProvider, AccountProvider.where(account_id: source["account_id"])
        .where("provider_type = ? OR provider_key = ?", manifest.account_type, manifest.provider_key), LINK_COLUMNS)
    end

    def verify_dual!(type, source_id, external_id)
      matches = @rows.fetch("mappings").values.select do |mapping|
        mapping["role"] == "external_account" && mapping["legacy_type"] == type &&
          mapping["legacy_id"] == source_id && mapping["external_account_id"] == external_id
      end
      raise InvalidGraph, "Dual provider link lacks its exact migration mapping" unless matches.one?
    end

    def snapshot
      proof = { "format" => FORMAT, "family_id" => @family_id }
      @rows.each { |kind, rows| proof[kind] = rows.values.sort_by { |row| [ row["type"].to_s, row.fetch("id") ] } }
      values = {
        proof: proof, legacy_items: @rows.fetch("legacy_items").keys.sort,
        legacy_accounts: @rows.fetch("legacy_accounts").sort.map { |(type, id), row| [ type, id, row.fetch("item_id") ] },
        connection_ids: @rows.fetch("connections").keys.sort, external_ids: @rows.fetch("external_accounts").keys.sort,
        control_ids: @rows.fetch("controls").keys.sort, mapping_ids: @rows.fetch("mappings").keys.sort
      }
      Snapshot.new(**Provider::AccountData::MigrationManifest.copy_value(values))
    end
end
