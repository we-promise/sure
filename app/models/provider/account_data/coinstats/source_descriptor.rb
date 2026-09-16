# Reviewed routing inputs, separated from historical monetary snapshots. Wallet
# addresses stay encrypted and preserve the exact legacy identity spelling.
class Provider::AccountData::Coinstats::SourceDescriptor
  FIELDS = %w[version source asset_id wallet_address address blockchain portfolio_id portfolio_account connection_id exchange_name
    protocol_id protocol_name protocol_logo investment_type asset_title symbol asset_name fiat legacy_account_uuid institution_logo].freeze

  def self.from_projection(projection)
    raise ArgumentError unless projection.provider_key == "coinstats" && projection.kind == :account
    raw = projection.payloads.fetch("raw_payload")
    raise ArgumentError unless raw.is_a?(Hash)
    raw = raw.with_indifferent_access
    raise ArgumentError if raw[:source].present? && !%w[wallet exchange defi].include?(raw[:source])
    raise ArgumentError if raw[:source] == "wallet" && raw[:portfolio_id].present?
    raise ArgumentError if raw[:source] == "defi" && raw[:portfolio_id].present?
    raise ArgumentError if raw[:source] == "exchange" && raw[:address].present? && raw[:blockchain].present?
    raise ArgumentError if raw[:source].blank? && raw[:portfolio_id].present? && (raw[:address].present? || raw[:blockchain].present?)
    identity = projection.identity
    metadata = raw[:coin].is_a?(Hash) ? raw[:coin].with_indifferent_access : raw
    source = if raw[:source] == "defi"
      "defi"
    elsif raw[:source] == "exchange" || raw[:portfolio_id].present?
      "exchange"
    elsif raw[:source] == "wallet" || (raw[:address].present? && raw[:blockchain].present?)
      "wallet"
    end
    descriptor = {
      "version" => 1, "source" => source, "asset_id" => identity["account_id"], "wallet_address" => identity["wallet_address"],
      "address" => raw[:address], "blockchain" => raw[:blockchain], "portfolio_id" => raw[:portfolio_id],
      "portfolio_account" => source == "exchange" && (ActiveModel::Type::Boolean.new.cast(raw[:portfolio_account]) == true || raw[:coins].is_a?(Array)),
      "connection_id" => raw[:connection_id], "exchange_name" => raw[:exchange_name],
      "protocol_id" => raw[:protocol_id], "protocol_name" => raw[:protocol_name], "protocol_logo" => raw[:protocol_logo],
      "investment_type" => raw[:investment_type], "asset_title" => raw[:asset_title],
      "symbol" => metadata[:symbol].presence || identity["account_id"].to_s.upcase,
      "asset_name" => metadata[:name].presence || projection.attributes["name"],
      "fiat" => [ metadata[:isFiat], raw[:isFiat] ].any? { |value| ActiveModel::Type::Boolean.new.cast(value) == true } ||
        [ metadata[:identifier], raw[:coinId], identity["account_id"] ].any? { |value| value.to_s.start_with?("FiatCoin") },
      "legacy_account_uuid" => projection.source_id,
      "institution_logo" => projection.metadata.dig("institution_metadata", "logo") || raw[:institution_logo]
    }.compact
    descriptor["portfolio_id"] ||= identity["wallet_address"] if source == "exchange"
    descriptor["fiat"] = false if descriptor["portfolio_account"]
    validate!(descriptor)
  rescue ArgumentError, KeyError, TypeError, NoMethodError
    raise Provider::AccountData::MigrationManifest::InvalidSource, "CoinStats account source routing is incomplete or ambiguous", cause: nil
  end

  def self.validate!(raw)
    raise ArgumentError unless raw.is_a?(Hash)
    data = raw.stringify_keys
    raise ArgumentError unless (data.keys - FIELDS).empty? && data["version"] == 1 && %w[wallet exchange defi].include?(data["source"])
    required = %w[asset_id legacy_account_uuid symbol asset_name]
    required += data["source"] == "exchange" ? %w[portfolio_id] : %w[address blockchain]
    required += %w[protocol_id asset_title] if data["source"] == "defi"
    raise ArgumentError unless required.all? { |key| data[key].is_a?(String) && data[key].present? }
    raise ArgumentError unless %w[portfolio_account fiat].all? { |key| [ true, false ].include?(data[key]) }
    raise ArgumentError if data["source"] != "exchange" && data["portfolio_account"]
    raise ArgumentError if data["portfolio_account"] && data["fiat"]
    raise ArgumentError unless data.except("version", "portfolio_account", "fiat").values.all? { |value| value.nil? || value.is_a?(String) }
    data
  end
end
