require "set"

# Frozen fallback input from the verified item archive. A fresh upstream catalog
# can replace it for one adapter; it never rewrites the migration evidence.
class Provider::AccountData::Trading212::InstrumentCatalog
  FORMAT = "trading212-retained-instruments/v1".freeze
  MAX_INSTRUMENTS = 100_000

  def self.live_input(connection:)
    Provider::AccountData::RetainedRow.new(connection: connection, provider_key: "trading212").item_descriptor
  end

  def self.build(connection:, observed_at:, external_accounts: nil)
    reader = Provider::AccountData::RetainedRow.new(connection: connection, provider_key: "trading212")
    expected = reader.item_descriptor
    row = reader.item
    unless row&.context == expected
      raise Provider::AccountData::StaleWriter, "Trading 212 catalog source changed during capture"
    end
    raw = row&.attributes&.fetch("raw_instruments_payload")
    items = raw.nil? ? [] : raw
    validate_items!(items)
    Provider::AccountData::MigrationManifest.copy_value(
      "format" => FORMAT, "source" => expected, "availability" => raw.nil? ? "absent" : "retained",
      "instruments" => items)
  end

  def self.instruments(snapshot)
    unless snapshot.is_a?(Hash) && snapshot["format"] == FORMAT &&
        %w[absent retained].include?(snapshot["availability"]) && snapshot.key?("source")
      raise Provider::AccountData::InvalidResponse, "Trading 212 retained catalog input is missing or invalid"
    end
    validate_items!(snapshot.fetch("instruments"))
  rescue KeyError
    raise Provider::AccountData::InvalidResponse, "Trading 212 retained catalog input is incomplete", cause: nil
  end

  def self.validate_items!(items)
    unless items.is_a?(Array) && items.size <= MAX_INSTRUMENTS
      raise Provider::AccountData::InvalidResponse, "Trading 212 retained catalog exceeds its bound or is malformed"
    end
    seen = Set.new
    items.each do |item|
      unless item.is_a?(Hash) && item["ticker"].is_a?(String) && item["ticker"].present? &&
          item["ticker"].bytesize <= 200 && seen.add?(item["ticker"]) &&
          %w[shortName name].all? { |key| item[key].nil? || (item[key].is_a?(String) && item[key].bytesize <= 2_048) }
        raise Provider::AccountData::InvalidResponse, "Trading 212 retained instruments require distinct valid identities"
      end
    end
    items
  end
  private_class_method :validate_items!
end
