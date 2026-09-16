require "digest"
require "json"

# An immutable wallet read shared by all the tracked assets at this address.
# The feeder, not an account adapter, owns obtaining and sealing this snapshot.
class Provider::AccountData::OnchainWallet::SnapshotArchive
  MAX_ASSETS = 10_000
  MAX_MOVEMENTS = 100_000
  MAX_BYTES = 32 * 1024 * 1024

  attr_reader :payload, :fingerprint, :chain, :address, :observed_at, :assets, :movements

  def self.capture(snapshot:, chain:, address:, observed_at:, evidence: {})
    raise ArgumentError unless snapshot.is_a?(Onchain::Snapshot)
    payload = {
      "version" => 1, "chain" => chain, "wallet_address" => address, "observed_at" => observed_at.to_time.utc.iso8601(9),
      "assets_truncated" => snapshot.assets_truncated, "history_truncated" => snapshot.history_truncated,
      "assets" => snapshot.assets.map do |asset|
        { "kind" => asset.kind, "symbol" => asset.symbol, "name" => asset.name, "decimals" => asset.decimals,
          "quantity" => decimal(asset.quantity).to_s("F"), "contract" => asset.contract_key, "notable" => asset.notable? }
      end,
      "movements" => snapshot.movements.map do |movement|
        { "external_id" => movement.external_id, "symbol" => movement.symbol, "contract" => movement.contract_key,
          "amount" => decimal(movement.amount).to_s("F"), "date" => movement.date&.iso8601 }
      end,
      "evidence" => evidence
    }
    new(payload).payload
  end

  def initialize(raw)
    raise ArgumentError unless raw.is_a?(Hash)
    data = raw.deep_stringify_keys
    required = %w[version chain wallet_address observed_at assets_truncated history_truncated assets movements evidence]
    raise ArgumentError unless data.keys.sort == required.sort && data["version"] == 1
    raise ArgumentError unless data["chain"].is_a?(String) && Onchain::Chains.exists?(data["chain"])
    raise ArgumentError unless data["wallet_address"].is_a?(String) && data["wallet_address"].present?
    raise ArgumentError unless data["observed_at"].is_a?(String)
    @observed_at = Time.iso8601(data["observed_at"])
    raise ArgumentError unless %w[assets_truncated history_truncated].all? { |key| [ true, false ].include?(data[key]) }
    raise ArgumentError unless data["assets"].is_a?(Array) && data["assets"].size <= MAX_ASSETS && data["movements"].is_a?(Array) && data["movements"].size <= MAX_MOVEMENTS
    @chain, @address = data.values_at("chain", "wallet_address")
    data["assets"].each { |asset| validate_asset!(asset) }
    data["movements"].each { |movement| validate_movement!(movement) }
    identities = data["assets"].map { |asset| [ asset["kind"], contract_key(asset["contract"], asset["kind"]) ] }
    raise ArgumentError unless identities.uniq == identities
    raise ArgumentError unless data["evidence"].is_a?(Hash)
    serialized = JSON.generate(canonical(data))
    raise ArgumentError if serialized.bytesize > MAX_BYTES
    @fingerprint = Digest::SHA256.hexdigest(serialized).freeze
    # Page's copy rules reject non-JSON evidence and provide recursive immutability.
    @payload = Provider::AccountData::Page.new(records: [], complete: false, evidence: data).evidence
    @assets, @movements = @payload.values_at("assets", "movements")
    @chain, @address = @payload.values_at("chain", "wallet_address")
    @observed_at.freeze
    freeze
  rescue ArgumentError, TypeError, KeyError, JSON::GeneratorError
    raise Provider::AccountData::InvalidResponse, "Invalid captured on-chain wallet snapshot", cause: nil
  end

  def assets_truncated?
    payload.fetch("assets_truncated")
  end

  def history_truncated?
    payload.fetch("history_truncated")
  end

  def asset_for(descriptor)
    assets.find do |asset|
      asset.fetch("kind") == descriptor.fetch("asset_kind") &&
        contract_key(asset["contract"], asset["kind"]) == descriptor["contract_address"]
    end
  end

  def movements_for(descriptor)
    movements.select do |movement|
      if descriptor["contract_address"]
        contract_key(movement["contract"], descriptor["asset_kind"]) == descriptor["contract_address"]
      else
        movement["contract"].nil? && movement["symbol"].casecmp?(descriptor.fetch("symbol"))
      end
    end
  end

  def inspect
    "#<#{self.class.name} assets=#{assets.size} movements=#{movements.size}>"
  end

  def self.decimal(value)
    raise ArgumentError if value.is_a?(Float)
    result = value.is_a?(BigDecimal) ? value : BigDecimal(value.to_s)
    raise ArgumentError unless result.finite?
    result
  end

  private
    def canonical(value)
      case value
      when Hash then value.keys.sort.to_h { |key| [ key, canonical(value.fetch(key)) ] }
      when Array then value.map { |item| canonical(item) }
      else value
      end
    end

    def validate_asset!(asset)
      raise ArgumentError unless asset.is_a?(Hash) && asset.keys.sort == %w[contract decimals kind name notable quantity symbol]
      raise ArgumentError unless Onchain::Chains.find!(chain).asset_kinds.include?(asset["kind"])
      %w[name symbol].each { |key| raise ArgumentError unless asset[key].is_a?(String) && asset[key].present? }
      raise ArgumentError unless asset["decimals"].is_a?(Integer) && asset["decimals"].between?(0, 255)
      raise ArgumentError unless [ true, false ].include?(asset["notable"])
      raise ArgumentError if self.class.decimal(asset["quantity"]).negative?
      if asset["kind"] == Onchain::Chains::NATIVE_KIND
        raise ArgumentError unless asset["contract"].nil?
      else
        raise ArgumentError unless asset["contract"].is_a?(String) && asset["contract"].present?
      end
    end

    def validate_movement!(movement)
      raise ArgumentError unless movement.is_a?(Hash) && movement.keys.sort == %w[amount contract date external_id symbol]
      %w[external_id symbol].each { |key| raise ArgumentError unless movement[key].is_a?(String) && movement[key].present? }
      raise ArgumentError unless movement["contract"].nil? || (movement["contract"].is_a?(String) && movement["contract"].present?)
      self.class.decimal(movement["amount"])
      raise ArgumentError unless movement["date"].nil? || (movement["date"].is_a?(String) && Date.iso8601(movement["date"]).iso8601 == movement["date"])
    end

    def contract_key(value, kind)
      value.nil? || Onchain::Chains.contract_case_sensitive?(kind) ? value : value.downcase
    end
end
