# Reads retained legacy observations before a Plaid cursor can be considered for
# migration. This never publishes Entries, makes HTTP requests, or seeds a native
# checkpoint. Legacy caches are not a proven complete delta for the item cursor.
class Provider::AccountData::Plaid::CheckpointBootstrapPlan
  class Conflict < StandardError; end

  FORMAT = "plaid-checkpoint-bootstrap/v1".freeze
  SECTIONS = %w[modified added removed].freeze
  MAX_CURSOR_BYTES = 64 * 1024
  Page = Data.define(:document, :next_cursor, :complete) do
    def replayable?
      document.fetch("blockers").empty?
    end

    def inspect
      "#<#{self.class.name} complete=#{complete} observations=#{document.fetch('observations').size}>"
    end
  end

  def initialize(control:, family:)
    unless control.is_a?(ProviderMigrationControl) && control.persisted? && family.is_a?(Family) && family.persisted? &&
        control.provider_key == "plaid" && control.legacy_type == "PlaidItem" && control.family_id == family.id
      raise ArgumentError, "Expected a Plaid migration control in the authorized family"
    end
    @control_id, @family_id = control.id, family.id
  end

  # One source account and at most limit physical cached rows per invocation.
  # A continuation is a read cursor, not proof that earlier rows were accepted.
  def page(cursor: nil, limit: 100)
    unless limit.is_a?(Integer) && (1..500).cover?(limit)
      raise ArgumentError, "Cached change page size must be between 1 and 500"
    end
    validate_cursor_shape!(cursor, limit)
    control = ProviderMigrationControl.find_by!(id: @control_id, family_id: @family_id, provider_key: "plaid", legacy_type: "PlaidItem")
    item = PlaidItem.find_by!(id: control.legacy_id, family_id: @family_id)
    Fence.with_exclusive(item) do
      ApplicationRecord.uncached do
        family = Family.find(@family_id)
        copier = Copier.new(provider_key: "plaid", legacy_item_id: item.id)
        retained = copier.verify_retained_quiesced_page(family: family, cursor: cursor&.fetch("source_cursor"), limit: 1)
        control = copier.control
        raise Conflict, "Plaid migration control changed before admission" unless control.id == @control_id
        item_mapping = control.provider_migration_mappings.find(retained.context.fetch("item_mapping_id"))
        item_archive = archive(copier, item_mapping)
        attributes = item_archive.fetch("attributes")
        pending = pending_context
        context = { "copy" => retained.context, "next_cursor" => attributes.fetch("next_cursor"),
          "item_id" => attributes.fetch("plaid_id"), "pending" => pending, "family_timezone" => family.timezone,
          "timezone" => normalization_timezone(family), "page_size" => limit }
        if cursor && cursor.fetch("context") != context
          raise Conflict, "Plaid cached-change continuation changed its source or processing context"
        end
        unless valid_provider_cursor?(context.fetch("next_cursor"))
          raise Conflict, "Copied Plaid cursor cannot be used by the native reader"
        end
        row = retained.rows.first
        if cursor && cursor["source_row"] && cursor["source_row"] != row
          raise Conflict, "Plaid cached account identity or archive changed"
        end
        build_page(copier: copier, control: control, context: context, row: row, retained: retained, cursor: cursor, limit: limit)
      end
    end
  rescue ActiveRecord::RecordNotFound, KeyError
    raise Conflict, "Plaid cached change ownership or archive is missing", cause: nil
  end

  def inspect
    "#<#{self.class.name}>"
  end

  private
    Copier = Provider::AccountData::MigrationCopier
    Fence = Provider::AccountData::LegacyWriterFence
    Value = Provider::AccountData::MigrationValue

    def validate_cursor_shape!(cursor, limit)
      return if cursor.nil?
      unless cursor.is_a?(Hash) && cursor.keys.all? { |key| key.is_a?(String) } &&
          cursor.keys.sort == %w[context format offset source_cursor source_row] &&
          Value.dump(cursor).bytesize <= MAX_CURSOR_BYTES && cursor["format"] == FORMAT && cursor["context"].is_a?(Hash) &&
          cursor["context"]["page_size"] == limit && cursor["offset"].is_a?(Integer) && cursor["offset"] >= 0 &&
          (cursor["source_cursor"].nil? || cursor["source_cursor"].is_a?(Hash)) &&
          (cursor["source_row"].nil? || cursor["source_row"].is_a?(Hash)) &&
          (cursor["source_row"] || cursor["offset"].zero?)
        raise Conflict, "Invalid Plaid cached-change continuation"
      end
    rescue ArgumentError, TypeError
      raise Conflict, "Invalid Plaid cached-change continuation", cause: nil
    end

    def archive(copier, mapping)
      copier.snapshot_for(mapping, max_bytes: Copier::RETAINED_ROW_BYTES, max_chunks: Copier::RETAINED_ARCHIVE_CHUNKS)
    end

    def pending_context
      override = ENV["PLAID_INCLUDE_PENDING"].present?
      selected = override ? Rails.configuration.x.plaid.include_pending : Provider::AccountData::RuntimeContext.pending_preference
      raise Conflict, "Plaid pending preference must be boolean" unless [ true, false ].include?(selected)
      { "override" => override, "include_pending" => selected }
    end

    # Unset family preferences must not inherit a worker's ambient/OS timezone.
    # Pin the deployment default explicitly so timestamp dates replay consistently.
    def normalization_timezone(family)
      selected = family.timezone.presence || Rails.application.config.time_zone.presence || "UTC"
      zone = ActiveSupport::TimeZone[selected] if selected.is_a?(String)
      raise Conflict, "Plaid normalization timezone is invalid" unless zone
      zone.name
    end

    def valid_provider_cursor?(cursor)
      cursor.nil? || (cursor.is_a?(String) && cursor.present? && cursor != "now" && cursor.bytesize <= 256)
    end

    def build_page(copier:, control:, context:, row:, retained:, cursor:, limit:)
      document = { "format" => FORMAT, "context" => context, "source_account" => row,
        "observations" => [], "blockers" => [], "cursor_accepted" => false,
        "requires_cached_change_acceptance" => true, "requires_cutover_reverification" => true,
        "historical_coverage" => "account_cache_generation_and_unassigned_removals_not_retained" }
      return finish_page(document, nil, true) unless row

      mapping = control.provider_migration_mappings.find_by!(id: row.fetch("mapping_id"), role: "external_account",
        legacy_type: "PlaidAccount", legacy_id: row.fetch("legacy_id"), family_id: @family_id,
        external_account_id: row.fetch("external_account_id"))
      account_attributes = archive(copier, mapping).fetch("attributes")
      cache = account_attributes.fetch("raw_transactions_payload")
      offset = cursor&.fetch("offset") || 0
      unless complete_cache_shape?(cache)
        raise Conflict, "Cannot resume an incomplete cached change set" unless offset.zero?
        code = cache == {} ? "cached_change_set_not_recorded" : "cached_change_set_incomplete_or_invalid"
        document["blockers"] << { "code" => code, "legacy_account_id" => row.fetch("legacy_id") }
        return next_account_page(document, retained, context)
      end
      total = SECTIONS.sum { |section| cache.fetch(section).size }
      raise Conflict, "Plaid cached-change continuation is beyond its account" if offset > total || (offset.positive? && offset == total)
      normalizer = Provider::AccountData::Plaid.new(client: Object.new.freeze, timezone: context.fetch("timezone"),
        observed_at: control.created_at, region: context.fetch("copy").fetch("region"), item_id: context.fetch("item_id"),
        include_pending: context.fetch("pending").fetch("include_pending"))
      emitted = 0
      position = 0
      SECTIONS.each do |section|
        rows = cache.fetch(section)
        first = [ offset - position, 0 ].max
        if first < rows.size && emitted < limit
          rows.slice(first, limit - emitted).each_with_index do |raw, index|
            source_index = first + index
            observation, blocker = normalize_observation(raw, section: section, source_index: source_index,
              ordinal: position + source_index, account_id: account_attributes.fetch("plaid_id"), normalizer: normalizer,
              include_pending: context.fetch("pending").fetch("include_pending"))
            document["observations"] << observation
            document["blockers"] << blocker if blocker
            emitted += 1
          end
        end
        position += rows.size
      end
      if offset + emitted < total
        next_cursor = { "format" => FORMAT, "context" => context, "source_cursor" => cursor&.fetch("source_cursor"),
          "source_row" => row, "offset" => offset + emitted }
        finish_page(document, next_cursor, false)
      else
        next_account_page(document, retained, context)
      end
    end

    def complete_cache_shape?(cache)
      cache.is_a?(Hash) && (cache.keys - SECTIONS).empty? && SECTIONS.all? { |section| cache[section].is_a?(Array) }
    end

    def normalize_observation(raw, section:, source_index:, ordinal:, account_id:, normalizer:, include_pending:)
      observation = { "section" => section, "source_index" => source_index, "ordinal" => ordinal, "raw" => raw,
        "disposition" => "unresolved", "canonical" => nil }
      unless raw.is_a?(Hash) && raw["transaction_id"].is_a?(String) && raw["transaction_id"].present? &&
          (section == "removed" ? raw["account_id"].nil? || raw["account_id"] == account_id : raw["account_id"] == account_id)
        return [ observation, { "code" => "cached_transaction_identity_invalid", "ordinal" => ordinal } ]
      end
      observation["external_id"] = raw.fetch("transaction_id")
      if section == "removed"
        observation["disposition"] = "removal_observation"
      else
        record = normalizer.normalize_legacy_transaction(raw, account: { external_id: account_id })
        observation["canonical"] = { "kind" => record.kind, "attributes" => record.attributes }
        observation["disposition"] = !include_pending && record[:pending] ? "pending_excluded" : "upsert_observation"
      end
      [ observation, nil ]
    rescue Provider::AccountData::InvalidResponse, ArgumentError, TypeError
      [ observation, { "code" => "cached_transaction_normalization_failed", "ordinal" => ordinal } ]
    end

    def next_account_page(document, retained, context)
      next_cursor = if retained.next_cursor
        { "format" => FORMAT, "context" => context, "source_cursor" => retained.next_cursor, "source_row" => nil, "offset" => 0 }
      end
      finish_page(document, next_cursor, retained.complete)
    end

    def finish_page(document, cursor, complete)
      document["complete"] = complete
      Page.new(document: Provider::AccountData::MigrationManifest.copy_value(document),
        next_cursor: Provider::AccountData::MigrationManifest.copy_value(cursor), complete: complete)
    end
end
