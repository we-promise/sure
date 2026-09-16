require "json"

# Tracking is an explicit user choice. New tokens found in a wallet are never
# selected merely because an explorer included them in a snapshot.
class Provider::AccountData::OnchainWallet::SourceDescriptor
  FIELDS = %w[version chain asset_kind wallet_address contract_address symbol name decimals ingestion_namespace].freeze

  def self.from_projection(projection)
    raise ArgumentError unless projection.provider_key == "onchain_wallet" && projection.kind == :account
    validate!(projection.identity_components.merge(
      "version" => 1, "symbol" => projection.attributes.fetch("symbol"),
      "name" => projection.attributes["name"].presence || projection.attributes.fetch("symbol"),
      "decimals" => projection.attributes.fetch("decimals"), "ingestion_namespace" => projection.ingestion_namespace))
  rescue ArgumentError, KeyError, TypeError
    raise Provider::AccountData::MigrationManifest::InvalidSource, "On-chain tracked asset routing is incomplete", cause: nil
  end

  def self.validate!(raw)
    raise ArgumentError unless raw.is_a?(Hash)
    data = raw.stringify_keys
    raise ArgumentError unless (data.keys - FIELDS).empty? && data["version"] == 1
    %w[chain asset_kind wallet_address symbol name ingestion_namespace].each do |key|
      raise ArgumentError unless data[key].is_a?(String) && data[key].present?
    end
    definition = Onchain::Chains.find(data["chain"])
    raise ArgumentError unless definition && definition.asset_kinds.include?(data["asset_kind"])
    raise ArgumentError unless data["decimals"].is_a?(Integer) && data["decimals"].between?(0, 255)
    raise ArgumentError unless data["ingestion_namespace"].match?(/\Aonchain_[A-Za-z0-9-]+\z/)
    if data["asset_kind"] == Onchain::Chains::NATIVE_KIND
      raise ArgumentError unless data["contract_address"].nil?
    else
      contract = data["contract_address"]
      raise ArgumentError unless contract.is_a?(String) && contract.present?
      if !Onchain::Chains.contract_case_sensitive?(data["asset_kind"]) && contract != contract.downcase
        raise ArgumentError
      end
    end
    data
  end

  def self.external_id(data)
    # Same ordered components as MigrationManifest. Do not replace this with a
    # delimiter join or normalize the spelling of an already tracked address.
    JSON.generate(%w[chain asset_kind wallet_address contract_address].map { |key| [ key, data[key] ] })
  end
end
