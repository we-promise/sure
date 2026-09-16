require "digest"

# A cache is evidence of a fetched response, not proof that its financial rows
# were posted. This read-only plan accounts for every retained cached identity
# before offering the maxima consumed by Binance::History. It never installs a
# cursor, repairs an Entry, resolves a security, or requests a provider price.
class Provider::AccountData::Binance::HistoryBootstrapPlan
  include Provider::AccountData::Normalization

  class InvalidContext < StandardError; end
  FORMAT = "binance-history-bootstrap-plan/v1".freeze
  MAX_ARCHIVE_BYTES = 32 * 1024 * 1024
  MAX_ARCHIVE_CHUNKS = 1_024
  MAX_RECORDS = 10_000
  MAX_DOCUMENT_BYTES = 16 * 1024 * 1024
  MAX_STATE_BYTES = 64 * 1024
  MAX_IDENTIFIER_BYTES = 1_024
  QUERY_SIZE = 250
  MARKETS = %w[spot futures].freeze
  Result = Data.define(:document) do
    def ready?
      document.fetch("blockers").empty?
    end

    def cached_history
      document.fetch("candidate_cached_history")
    end

    def inspect
      "#<#{self.class.name} ready=#{ready?} rows=#{document.fetch('rows').size}>"
    end
  end

  def initialize(mapping:, family:)
    @mapping, @family = mapping, family
  end

  # Run outside a transaction. The advisory permit covers declared legacy
  # writers; one repeatable-read snapshot keeps this advisory report coherent
  # with concurrent user edits. Neither is a durable cutover authorization.
  def call(expected_context: nil)
    with_retained_plan(expected_context: expected_context) { |result| result }
  end

  # Installation must finish before this same permit and coherent snapshot end.
  # The consumer still verifies permanent financial proofs; ready? alone does
  # not authorize a seed. This seam never accepts a caller-supplied plan.
  def with_retained_plan(expected_context: nil)
    raise ArgumentError, "A retained plan consumer is required" unless block_given?
    unless family.is_a?(Family) && family.persisted? && mapping.is_a?(ProviderMigrationMapping) && mapping.persisted?
      raise InvalidContext, "History planning requires an authorized copied account"
    end
    initial = ProviderMigrationMapping.where(id: mapping.id, family_id: family.id, role: "external_account", legacy_type: "BinanceAccount").first!
    owner = initial.provider_migration_control
    unless owner.family_id == family.id && owner.provider_key == "binance" && owner.legacy_type == "BinanceItem"
      raise InvalidContext, "History planning requires an authorized Binance copy"
    end
    item = BinanceItem.find_by!(id: owner.legacy_id, family_id: family.id)
    @admitted_control_id, @admitted_item_id = owner.id, item.id
    Provider::AccountData::LegacyWriterFence.with_exclusive(item) do
      ApplicationRecord.uncached do
        ApplicationRecord.transaction(isolation: :repeatable_read) do
          prepare_context!
          binding = context_binding
          if expected_context && expected_context != binding
            raise InvalidContext, "History plan belongs to another retained copy or financial link revision"
          end
          rows, blockers = cache_rows
          match_ledger!(rows, blockers)
          candidate = history_seed(rows) if blockers.empty?
          document = { "context" => binding, "rows" => rows, "blockers" => blockers,
            "candidate_cached_history" => candidate, "requires_identity_publication" => true,
            "requires_quiesced_reverification" => true, "upstream_history_complete" => false }
          if Value.dump(document).bytesize > MAX_DOCUMENT_BYTES
            raise InvalidContext, "History plan exceeds its document bound"
          end
          yield Result.new(document: Manifest.copy_value(document))
        end
      end
    end
  rescue ActiveRecord::RecordNotFound, Copier::Conflict, Copier::SourceChanged, Manifest::InvalidSource, ArgumentError, TypeError, KeyError
    raise InvalidContext, "Retained Binance history context is invalid or exceeds its read bound", cause: nil
  end

  private
    Value = Provider::AccountData::MigrationValue
    Manifest = Provider::AccountData::MigrationManifest
    Copier = Provider::AccountData::MigrationCopier
    attr_reader :mapping, :family, :control, :connection, :external, :link, :account, :archive

    def prepare_context!
      @mapping = mapping.reload
      @control = mapping.provider_migration_control.reload
      bounded_document(control, :high_water_mark)
      bounded_document(control, :audit_results)
      unless control.id == @admitted_control_id && control.legacy_id == @admitted_item_id &&
          mapping.family_id == family.id && control.family_id == family.id && mapping.role == "external_account" &&
          mapping.legacy_type == "BinanceAccount" && control.legacy_type == "BinanceItem" && control.provider_key == "binance"
        raise InvalidContext, "Retained Binance mapping changed its admitted owner"
      end
      copier = Copier.new(provider_key: "binance", legacy_item_id: control.legacy_id)
      page = copier.verify_retained_quiesced_page(family: family, limit: 1)
      unless page.rows.first&.fetch("mapping_id") == mapping.id
        # The public verifier pins the full copy context and checks after_id
        # against this item's source inventory. At most one additional page is
        # needed; never scan or decode all of a connection's account archives.
        previous_id = BinanceAccount.where(binance_item_id: control.legacy_id).where("id < ?", mapping.legacy_id).order(id: :desc).pick(:id)
        raise InvalidContext, "Retained Binance account is absent from its inventory" unless previous_id
        page = copier.verify_retained_quiesced_page(family: family, cursor: page.context.merge("after_id" => previous_id), limit: 1)
      end
      row = page.rows.sole
      unless row.values_at("mapping_id", "legacy_id", "external_account_id", "source_checksum", "disposition") ==
          [ mapping.id, mapping.legacy_id, mapping.external_account_id, mapping.source_checksum, "linked" ]
        raise InvalidContext, "Retained Binance account has another copied binding"
      end
      @retained_context, @retained_account = page.context, row
      @control = copier.control.reload
      @external = mapping.external_account.reload
      @connection = external.provider_connection.reload
      @archive = copier.snapshot_for(mapping, max_bytes: MAX_ARCHIVE_BYTES, max_chunks: MAX_ARCHIVE_CHUNKS)
      unless archive.fetch("attributes").fetch("account_type") == "combined" && external.external_id == "combined" && external.identity_namespace == "connection"
        raise InvalidContext, "Binance history requires reconciliation of the combined account topology"
      end
      @link = AccountProvider.find_by(id: row.fetch("account_provider_id"), external_account_id: external.id)
      @account = link&.account
      unless link && account && link.family_id == family.id && account.family_id == family.id && account.id == row.fetch("account_id") &&
          link.lock_version == row.fetch("account_provider_revision") && link.provider_key == "binance" &&
          link.provider_type == "BinanceAccount" && link.provider_id == mapping.legacy_id
        raise InvalidContext, "History planning requires the retained Binance financial account link"
      end
      if account.account_providers.where("provider_type = ? OR provider_key = ?", "BinanceAccount", "binance").where.not(id: link.id).exists?
        raise InvalidContext, "Binance financial source ownership is ambiguous"
      end
    end

    def bounded_document(record, attribute)
      bytes = record.class.where(id: record.id).pick(Arel.sql("COALESCE(octet_length(#{attribute}::text), 0)"))
      raise InvalidContext, "Migration state exceeds its read bound" if bytes.to_i > MAX_STATE_BYTES * 2
      document = record.public_send(attribute)
      unless document.is_a?(Hash) && Value.dump(document).bytesize <= MAX_STATE_BYTES
        raise InvalidContext, "Migration state exceeds its read bound"
      end
      document
    end

    def context_binding
      { "format" => FORMAT, "manifest_version" => Manifest::VERSION, "family_id" => family.id,
        "provider_key" => "binance", "provider_connection_id" => connection.id, "migration_control_id" => control.id,
        "copy_run_id" => @retained_context.fetch("copy_run_id"), "item_mapping_id" => @retained_context.fetch("item_mapping_id"),
        "item_checksum" => @retained_context.fetch("item_checksum"), "retained_copy_context" => @retained_context, "retained_account_binding" => @retained_account,
        "migration_mapping_id" => mapping.id, "legacy_item_id" => control.legacy_id, "legacy_account_id" => mapping.legacy_id,
        "archive_checksum" => mapping.source_checksum, "archive_column" => "raw_transactions_payload",
        "external_account_id" => external.id, "external_account_external_id" => external.external_id,
        "identity_namespace" => external.identity_namespace, "account_id" => account.id,
        "account_currency" => account.currency, "accountable_type" => account.accountable_type, "accountable_id" => account.accountable_id,
        "account_provider_id" => link.id, "account_provider_revision" => link.lock_version,
        "writer_epoch" => control.writer_epoch, "connection_writer_epoch" => connection.writer_epoch,
        "credential_revision" => connection.credential_revision, "region" => connection.region, "environment" => connection.environment }
    end

    def cache_rows
      cache = archive.fetch("attributes").fetch("raw_transactions_payload") || {}
      raise InvalidContext, "Unreviewed Binance cache structure" unless cache.is_a?(Hash) && (cache.keys - %w[spot futures p2p fetched_at]).empty?
      rows, blockers, identities = [], [], {}
      count = 0
      MARKETS.each do |market|
        pairs = cache.fetch(market, {})
        raise InvalidContext, "Unreviewed Binance market cache" unless pairs.is_a?(Hash)
        pairs.keys.sort.each do |pair|
          raw_rows = pairs.fetch(pair)
          raise InvalidContext, "Unreviewed Binance pair cache" unless raw_rows.is_a?(Array)
          raw_rows.each_with_index do |raw, index|
            count += 1
            check_count!(count)
            path = [ "attributes", "raw_transactions_payload", market, pair, index ]
            append_row!(rows, blockers, identities, raw, path) { trade_descriptor(raw, market, pair) }
          end
        end
      end
      p2p = cache.fetch("p2p", [])
      raise InvalidContext, "Unreviewed Binance P2P cache" unless p2p.is_a?(Array)
      p2p.each_with_index do |raw, index|
        count += 1
        check_count!(count)
        path = [ "attributes", "raw_transactions_payload", "p2p", index ]
        append_row!(rows, blockers, identities, raw, path) { p2p_descriptor(raw) }
      end
      [ rows, blockers ]
    end

    def append_row!(rows, blockers, identities, raw, path)
      row = yield
      row["raw_checksum"] = Digest::SHA256.hexdigest(Value.dump(raw))
      row["archive_paths"] = [ path ]
      previous = identities[row.fetch("external_id")]
      if previous && previous["raw_checksum"] == row["raw_checksum"] && previous.except("archive_paths") == row.except("archive_paths")
        previous.fetch("archive_paths") << path
      else
        if previous
          blockers << { "code" => "conflicting_cached_identity", "external_id" => row.fetch("external_id"), "archive_paths" => [ *previous.fetch("archive_paths"), path ] }
        end
        rows << row
        identities[row.fetch("external_id")] = row
      end
    rescue ArgumentError, TypeError, KeyError
      blockers << { "code" => "unreviewed_cached_record", "archive_paths" => [ path ], "raw_checksum" => Digest::SHA256.hexdigest(Value.dump(raw)) }
    end

    def trade_descriptor(raw, market, pair)
      data = normalized_object(raw)
      symbol = checked_pair(pair)
      id = integer_id(data.fetch(:id))
      # Legacy interpolated the original value; native normalizes it to Integer.
      raise ArgumentError unless data[:id].to_s == id.to_s
      timestamp = cached_timestamp(data.fetch(:time))
      raise ArgumentError if data.key?(:symbol) && data[:symbol] != pair
      quantity = normalized_decimal(data.fetch(:qty))
      price = normalized_decimal(data.fetch(:price))
      value = data[:quoteQty].nil? ? quantity * price : normalized_decimal(data[:quoteQty])
      fee = normalized_decimal(data.fetch(:commission))
      buyer = data.key?(:isBuyer) ? data[:isBuyer] : data[:buyer]
      raise ArgumentError unless quantity.positive? && !price.negative? && !value.negative? && !fee.negative? && [ true, false ].include?(buyer)
      checked_symbol(data.fetch(:commissionAsset)) unless fee.zero?
      external_id = "binance_#{market}_#{pair}_#{id}"
      { "market" => market, "pair" => pair, "symbol" => symbol, "id" => id, "timestamp_ms" => timestamp,
        "external_id" => external_id, "members" => [ { "external_id" => external_id, "entryable_type" => "Trade" } ] }
    end

    def p2p_descriptor(raw)
      data = normalized_object(raw)
      order_id = normalized_id(data.fetch(:orderNumber))
      raise ArgumentError if order_id.bytesize > MAX_IDENTIFIER_BYTES || order_id.end_with?("_funding") || order_id.match?(/[[:cntrl:]]/)
      raise ArgumentError unless %w[BUY SELL].include?(data[:tradeType])
      timestamp = cached_timestamp(data.fetch(:createTime))
      normalized_currency(data.fetch(:fiat))
      checked_symbol(data.fetch(:asset))
      gross = normalized_decimal(data.fetch(:amount))
      net = data[:takerAmount].nil? ? gross : normalized_decimal(data[:takerAmount])
      amounts = [ normalized_decimal(data.fetch(:totalPrice)), normalized_decimal(data.fetch(:unitPrice)),
        data[:takerCommission].nil? ? BigDecimal("0") : normalized_decimal(data[:takerCommission]) ]
      raise ArgumentError unless gross.positive? && net.positive? && amounts.none?(&:negative?)
      external_id = "binance_p2p_#{order_id}"
      { "market" => "p2p", "order_id" => order_id, "side" => data[:tradeType], "timestamp_ms" => timestamp,
        "external_id" => external_id, "members" => [ { "external_id" => external_id, "entryable_type" => "Trade" },
          { "external_id" => "#{external_id}_funding", "entryable_type" => "Transaction" } ] }
    end

    def match_ledger!(rows, blockers)
      members = rows.flat_map { |row| row.fetch("members") }
      members.each_slice(QUERY_SIZE) do |slice|
        ids = slice.map { |member| member.fetch("external_id") }.uniq
        inventory = account.entries.where(external_id: ids).limit(QUERY_SIZE * 2 + 1)
          .pluck(:id, :external_id, :source, :plaid_id, :entryable_type, :entryable_id)
        raise InvalidContext, "Cached history has an excessive ledger identity inventory" if inventory.size > QUERY_SIZE * 2
        by_id = inventory.group_by { |_, external_id, *| external_id }
        entryables = %w[Trade Transaction].to_h do |type|
          typed_ids = inventory.filter_map { |_, _, _, _, entry_type, id| id if entry_type == type }
          counts = Entry.where(entryable_type: type, entryable_id: typed_ids).group(:entryable_id).count
          [ type, [ type.constantize.where(id: typed_ids).pluck(:id), counts ] ]
        end
        slice.each do |member|
          found = by_id.fetch(member.fetch("external_id"), [])
          code = if found.empty?
            "cached_record_not_posted"
          elsif found.size != 1
            "identity_claimed_by_multiple_entries"
          else
            id, _, source, plaid_id, type, entryable_id = found.sole
            if source != "binance" || plaid_id.present?
              "conflicting_source"
            elsif type != member.fetch("entryable_type")
              "incompatible_financial_type"
            elsif !entryables.fetch(type).first.include?(entryable_id) || entryables.fetch(type).last[entryable_id] != 1
              "ambiguous_or_missing_entryable"
            else
              member.merge!("entry_id" => id, "entryable_id" => entryable_id)
              nil
            end
          end
          member["status"] = code || "posted"
          blockers << { "code" => code, "external_id" => member.fetch("external_id") } if code
        end
      end
      rows.each do |row|
        row["status"] = row.fetch("members").all? { |member| member["status"] == "posted" } ? "posted" : "unresolved"
      end
    end

    def history_seed(rows)
      seed = { "ids" => { "spot" => {}, "futures" => {} }, "p2p_after" => nil }
      rows.each do |row|
        if row.fetch("market") == "p2p"
          seed["p2p_after"] = [ seed["p2p_after"], row.fetch("timestamp_ms") ].compact.max
        else
          pairs = seed.fetch("ids").fetch(row.fetch("market"))
          pairs[row.fetch("pair")] = [ pairs[row.fetch("pair")], row.fetch("id") ].compact.max
        end
      end
      seed
    end

    def checked_pair(pair)
      checked_symbol(pair)
      quote = Provider::AccountData::Binance::QUOTES.find { |suffix| pair.end_with?(suffix) }
      raise ArgumentError unless quote
      symbol = checked_symbol(pair.delete_suffix(quote))
      # The native task builder excludes stablecoin bases. Do not seed a pair it
      # would never request, even if its cached records happen to be posted.
      raise ArgumentError if Provider::AccountData::Binance::STABLECOINS.include?(symbol)
      symbol
    end

    def checked_symbol(value)
      raise ArgumentError unless value.is_a?(String) && value.bytesize <= MAX_IDENTIFIER_BYTES && value.match?(/\A[A-Z0-9]+\z/)
      value
    end

    def integer_id(value)
      raise ArgumentError unless value.is_a?(Integer) || (value.is_a?(String) && value.bytesize <= MAX_IDENTIFIER_BYTES && value.match?(/\A[0-9]+\z/))
      result = value.to_i
      raise ArgumentError if result.negative?
      result
    end

    def cached_timestamp(value)
      timestamp = integer_id(value)
      raise ArgumentError if timestamp > (mapping.copied_at.to_r * 1000).floor
      timestamp
    end

    def check_count!(count)
      raise InvalidContext, "Binance cache exceeds its record planning bound" if count > MAX_RECORDS
    end
end
