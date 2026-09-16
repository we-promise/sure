# Copy-time account kinds are local identities. Only the exact retained remote
# account ID can connect one of them to a restored session's portfolio or cash.
class Provider::AccountData::TradeRepublic::RetainedPortfolio
  VERSION = 1
  MAX_ACCOUNTS = 1_000
  MAX_ARCHIVE_BYTES = 32 * 1024 * 1024
  MAX_POSITIONS = 10_000

  def self.live_input(connection:)
    new(connection).live_input
  end

  def self.build(connection:, observed_at:, external_accounts: nil)
    new(connection).build(observed_at: observed_at, external_accounts: external_accounts)
  end

  # Match the factory's captured inventory without querying mutable source rows.
  def self.adapter_inputs(snapshot:, external_accounts:)
    unless snapshot.is_a?(Hash) && snapshot["version"] == VERSION && snapshot["accounts"].is_a?(Hash)
      raise Provider::AccountData::StaleWriter, "Trade Republic retained topology is missing"
    end
    inventory = external_accounts.map(&:with_indifferent_access).index_by { |row| row.fetch(:id) }
    raise ArgumentError unless inventory.size == external_accounts.size
    topology, positions, sources = {}, {}, {}
    snapshot.fetch("accounts").each do |id, value|
      row = inventory.fetch(id)
      context = value.fetch("context")
      binding = context.fetch("account_binding")
      link, financial = binding.values_at("link", "financial_context")
      expected_link = financial && {
        id: financial.fetch("id"), currency: financial.fetch("currency"), accountable_type: financial.fetch("accountable_type"),
        accountable_id: financial.fetch("accountable_id"), account_provider_id: link.fetch("id"), account_provider_revision: link.fetch("lock_version")
      }.with_indifferent_access
      unless row.values_at(:external_id, :identity_namespace, :linked_account) ==
          [ context.fetch("external_id"), "connection", expected_link ] && context.dig("source", "target_id") == id
        raise Provider::AccountData::StaleWriter, "Trade Republic retained account binding changed"
      end
      local_id = row.fetch(:external_id)
      topology[local_id] = value.slice("kind", "remote_id", "owner_id", "currency").merge("external_account_id" => id)
      positions[local_id] = value.fetch("positions")
      sources[local_id] = { "source" => context.fetch("source"), "last_positions_sync" => value.fetch("last_positions_sync") }
    end
    owners = topology.values.map { |value| value.fetch("owner_id") }.uniq
    raise ArgumentError if owners.size > 1 || topology.values.map { |value| value.fetch("kind") }.uniq.size != topology.size
    if owners.any?
      expected_ids = %w[portfolio cash].map do |kind|
        topology.find { |_id, value| value.fetch("kind") == kind }&.first || (kind == "cash" ? "cash:#{owners.sole}" : owners.sole)
      end
      unless inventory.values.all? { |row| row[:identity_namespace] == "connection" && expected_ids.include?(row[:external_id]) }
        raise Provider::AccountData::StaleWriter, "Trade Republic inventory has unresolved account topology"
      end
    end
    Manifest.copy_value(topology: topology, cached_positions: positions, cached_position_sources: sources)
  rescue KeyError, ArgumentError, TypeError, NoMethodError
    raise Provider::AccountData::StaleWriter, "Trade Republic retained topology is invalid", cause: nil
  end

  def initialize(connection)
    @connection = connection
    @reader = Provider::AccountData::RetainedRow.new(connection: connection, provider_key: "trade_republic")
  end

  # Descriptors and current bindings only: no positions or timeline payloads are
  # decrypted on each request. New unlinked native discovery is not a new alias.
  def live_input
    require_admission!
    accounts = sources.filter_map do |external|
      descriptor = reader.account_descriptor(external)
      if descriptor.nil?
        raise ArgumentError if %w[portfolio cash].include?(external.external_id)
        next
      end
      link, financial = external.account_provider, external.current_account
      if (link.nil? != financial.nil?) || (link && (link.family_id != connection.family_id || link.provider_key != "trade_republic" || financial&.family_id != connection.family_id))
        raise ArgumentError
      end
      [ external.id, {
        "external_id" => external.external_id, "identity_namespace" => external.identity_namespace,
        "currency" => external.currency, "status" => external.status, "financial_status" => financial&.status,
        "source" => descriptor, "account_binding" => { "format" => Copier::ACCOUNT_BINDING_FORMAT,
          "link" => link&.attributes&.slice(*Copier::RETAINED_LINK_COLUMNS),
          "financial_context" => financial&.attributes&.slice(*Copier::RETAINED_FINANCIAL_CONTEXT_COLUMNS) }
      } ]
    end.to_h
    Manifest.copy_value("version" => VERSION, "provider_connection_id" => connection.id, "family_id" => connection.family_id,
      "item" => reader.item_descriptor, "accounts" => accounts)
  rescue KeyError, ArgumentError, TypeError, ActiveRecord::RecordNotFound
    raise Provider::AccountData::StaleWriter, "Trade Republic retained inventory is invalid", cause: nil
  end

  def build(observed_at:, external_accounts: nil)
    raise ArgumentError unless observed_at.is_a?(Time) || observed_at.is_a?(DateTime)
    input = live_input
    inventory = sources.index_by(&:id)
    if external_accounts && (external_accounts.map(&:id).sort != inventory.keys.sort ||
        external_accounts.any? { |external| external.family_id != connection.family_id || external.provider_connection_id != connection.id })
      raise ArgumentError
    end
    total_bytes = 0
    accounts = input.fetch("accounts").to_h do |id, context|
      external = inventory.fetch(id)
      retained = reader.account(external)
      raise ArgumentError unless retained && retained.context == context.fetch("source")
      total_bytes += retained.byte_size
      raise Provider::AccountData::IncompletePage, "Trade Republic retained portfolios exceed their byte bound" if total_bytes > MAX_ARCHIVE_BYTES
      disposition = Provider::AccountData::RetainedAccountBinding.classify!(retained: retained, external_account: external)
      attributes = retained.attributes
      kind = attributes.fetch("kind")
      remote = attributes.fetch("trade_republic_account_id")
      unless %w[portfolio cash].include?(kind) && external.external_id == kind && external.identity_namespace == "connection" &&
          attributes.values_at("id", "trade_republic_item_id", "currency") ==
            [ retained.context.fetch("legacy_id"), input.fetch("item").fetch("legacy_id"), external.currency ] &&
          remote.is_a?(String) && remote.present? && remote.strip == remote && remote.bytesize <= 1_024
        raise ArgumentError
      end
      owner = kind == "cash" ? remote.delete_prefix("cash:") : remote
      raise ArgumentError if owner.blank? || owner.start_with?("cash:") || (kind == "cash" && remote != "cash:#{owner}")
      timestamp = attributes.fetch("last_positions_sync")
      raise ArgumentError unless timestamp.nil? || timestamp.is_a?(Time)
      rows = retained_positions(attributes.fetch("raw_positions_payload"))
      raise ArgumentError if kind == "cash" && rows.any?
      # Remote aliases are needed even when the source is unlinked. Its old
      # financial quote fallback is not: preserve topology without reusing it.
      rows, timestamp = [], nil if disposition == :detached
      [ id, { "context" => context, "kind" => kind, "remote_id" => remote, "owner_id" => owner,
        "currency" => external.currency, "positions" => rows, "last_positions_sync" => timestamp&.getutc&.iso8601(9) } ]
    end
    unless accounts.values.map { |row| row.fetch("kind") }.uniq.size == accounts.size && accounts.values.map { |row| row.fetch("owner_id") }.uniq.size <= 1
      raise ArgumentError
    end
    Manifest.copy_value(input.merge("accounts" => accounts))
  rescue Copier::Conflict, KeyError, ArgumentError, TypeError, NoMethodError
    raise Provider::AccountData::StaleWriter, "Trade Republic retained portfolio requires explicit reconciliation", cause: nil
  end

  def inspect
    "#<#{self.class.name}>"
  end

  private
    Copier = Provider::AccountData::MigrationCopier
    Manifest = Provider::AccountData::MigrationManifest
    attr_reader :connection, :reader

    def require_admission!
      unless connection.persisted? && connection.provider_key == "trade_republic" && ProviderConnection.connection.open_transactions.positive?
        raise Provider::AccountData::StaleWriter, "Trade Republic retained portfolio requires admitted connection locks"
      end
    end

    def sources
      rows = connection.external_accounts.where(family_id: connection.family_id).order(:id).limit(MAX_ACCOUNTS + 1).to_a
      raise Provider::AccountData::IncompletePage, "Trade Republic account inventory exceeds its bound" if rows.size > MAX_ACCOUNTS
      rows
    end

    def retained_positions(raw)
      rows = raw.nil? ? [] : raw
      raise ArgumentError unless rows.is_a?(Array) && rows.size <= MAX_POSITIONS
      values = rows.map do |position|
        raise ArgumentError unless position.is_a?(Hash)
        isin, price = position.values_at("isin", "price")
        raise ArgumentError unless isin.is_a?(String) && isin.present? && isin.strip == isin && isin.bytesize <= 256
        if !price.nil?
          raise ArgumentError unless price.is_a?(String) || price.is_a?(Numeric)
          price = BigDecimal(price.to_s)
          raise ArgumentError unless price.finite? && price >= 0
        end
        { "isin" => isin, "price" => price }
      end
      raise ArgumentError unless values.map { |row| row.fetch("isin") }.uniq.size == values.size
      values
    end
end
