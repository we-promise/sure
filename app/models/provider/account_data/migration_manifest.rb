require "bigdecimal"
require "date"
require "json"
require_relative "migration_manifest_catalog"

# A reviewed, lossless projection of a legacy row. This class never creates
# financial records, calls a provider or changes connection routing.
class Provider::AccountData::MigrationManifest
  class InvalidSource < StandardError; end
  class EncryptionRequired < StandardError; end

  VERSION = 1
  BUCKETS = %i[identity attributes credentials settings metadata checkpoints sensitive_data payloads].freeze
  PROTECTED_BUCKETS = %i[credentials sensitive_data payloads].freeze
  SOURCE_TYPES = %i[uuid string text datetime date decimal integer bigint jsonb boolean].freeze

  IDENTITIES = {
    "akahu" => %w[account_id],
    "binance" => %w[account_type],
    "brex" => %w[account_id],
    "coinbase" => %w[account_id],
    "coinstats" => %w[account_id wallet_address],
    "enable_banking" => %w[uid],
    "ibkr" => %w[ibkr_account_id],
    "indexa_capital" => %w[indexa_capital_account_id],
    "kraken" => %w[account_id],
    "lunchflow" => %w[account_id],
    "mercury" => %w[account_id],
    "monobank" => %w[account_id],
    "onchain_wallet" => %w[chain asset_kind wallet_address contract_address],
    "plaid" => %w[plaid_id],
    "questrade" => %w[questrade_account_id],
    "redbark" => %w[redbark_account_id],
    "simplefin" => %w[account_id],
    "snaptrade" => %w[snaptrade_account_id],
    "sophtron" => %w[account_id],
    "trade_republic" => %w[kind],
    "trading212" => %w[trading212_account_id],
    "up" => %w[account_id],
    "wise" => %w[balance_id]
  }.transform_values { |fields| fields.map(&:freeze).freeze }.freeze

  # These columns move with the independently renewable Enable Banking grant.
  # Application credentials remain owned by the ProviderConnection.
  AUTHORIZATION_FIELDS = %w[
    authorization_id session_id session_expires_at aspsp_id aspsp_name
    aspsp_auth_approach aspsp_maximum_consent_validity aspsp_psu_types
    aspsp_required_psu_headers last_psu_ip psu_type
  ].map(&:freeze).freeze

  class Projection
    attr_reader :provider_key, :kind, :source_table, :source_type, :buckets,
                :column_metadata, :external_id, :identity_components

    def initialize(provider_key:, kind:, source_table:, source_type:, buckets:, column_metadata:, external_id:, identity_components:)
      @provider_key = provider_key.freeze
      @kind = kind
      @source_table = source_table.freeze
      @source_type = source_type.freeze
      @buckets = buckets.freeze
      @column_metadata = Provider::AccountData::MigrationManifest.copy_value(column_metadata)
      @external_id = external_id&.freeze
      @identity_components = identity_components.freeze
      freeze
    end

    BUCKETS.each { |bucket| define_method(bucket) { buckets.fetch(bucket) } }

    def source_id
      identity.fetch("id")
    end

    def source_attributes
      buckets.values.reduce({}) { |result, values| result.merge(values) }
    end

    def identity_namespace
      "connection"
    end

    # On-chain holding and movement IDs already contain the old source-row UUID.
    # They must not switch to the new ExternalAccount UUID during migration.
    def ingestion_namespace
      "onchain_#{source_id}" if provider_key == "onchain_wallet" && kind == :account
    end

    def unresolved_identity?
      kind == :account && external_id.nil?
    end

    def inspect
      "#<#{self.class.name} provider=#{provider_key} kind=#{kind}>"
    end
  end

  class << self
    def for(provider_key)
      key = provider_key.to_s
      key = "plaid" if key == "plaid_eu"
      raise InvalidSource, "Unregistered legacy provider" unless IDENTITIES.key?(key)

      new(key)
    end
    alias_method :fetch, :for

    def all
      IDENTITIES.keys.map { |key| new(key) }
    end

    def provider_keys
      IDENTITIES.keys
    end

    def offering_keys
      (provider_keys + [ "plaid_eu" ]).sort
    end

    # Target assignments must pass through a declared AR encryptor. No fallback
    # to plaintext is allowed when moving source credentials or private details.
    # The caller owns the enclosing transaction and target save.
    def assign_encrypted!(target, attribute:, values:)
      encrypted = target.class.respond_to?(:encrypted_attributes) && target.class.encrypted_attributes
      unless encrypted && encrypted.map(&:to_s).include?(attribute.to_s)
        raise EncryptionRequired, "Migration requires encrypted #{attribute} storage"
      end
      raise InvalidSource, "Encrypted migration data must be a hash" unless values.is_a?(Hash)

      target.public_send("#{attribute}=", copy_value(values))
      target
    end

    def copy_value(value)
      if defined?(ActiveSupport::TimeWithZone) && value.is_a?(ActiveSupport::TimeWithZone)
        return value.dup.freeze
      end

      case value
      when Hash
        value.to_h { |key, item| [ copy_value(key), copy_value(item) ] }.freeze
      when Array
        value.map { |item| copy_value(item) }.freeze
      when String, Date, Time
        value.dup.freeze
      when BigDecimal
        raise InvalidSource, "Non-finite source decimal" unless value.finite?
        value
      when Float
        raise InvalidSource, "Non-finite source number" unless value.finite?
        value
      when Integer, TrueClass, FalseClass, NilClass, Symbol
        value
      else
        raise InvalidSource, "Unsupported source value type #{value.class.name}"
      end
    end
  end

  attr_reader :provider_key

  def initialize(provider_key)
    raise InvalidSource, "Unregistered legacy provider" unless IDENTITIES.key?(provider_key)

    @provider_key = provider_key.dup.freeze
    freeze
  end

  def item_table
    "#{provider_key}_items"
  end

  def account_table
    "#{provider_key}_accounts"
  end

  def item_type
    "#{provider_key.split('_').map(&:capitalize).join}Item"
  end

  def account_type
    "#{provider_key.split('_').map(&:capitalize).join}Account"
  end

  def account_foreign_key
    "#{provider_key}_item_id"
  end

  def columns(kind)
    dispositions(kind).values.flatten
  end

  def dispositions(kind)
    table = case kind
    when :item then item_table
    when :account then account_table
    else raise InvalidSource, "Source kind must be item or account"
    end
    Provider::AccountData::MigrationManifestCatalog::TABLES.fetch(table)
  end

  def validate_columns!(kind, actual_columns, encrypted_columns: [])
    expected = columns(kind)
    actual = actual_columns.map(&:to_s)
    duplicates = expected.tally.select { |_, count| count != 1 }.keys
    unknown = actual - expected
    missing = expected - actual
    unless unknown.empty? && missing.empty? && duplicates.empty?
      raise InvalidSource, "Manifest mismatch for #{provider_key} #{kind}: unknown=#{unknown.sort.join(',')} missing=#{missing.sort.join(',')} duplicate=#{duplicates.sort.join(',')}"
    end

    protected_columns = dispositions(kind).slice(*PROTECTED_BUCKETS).values.flatten
    misplaced = encrypted_columns.map(&:to_s) - protected_columns
    raise InvalidSource, "Encrypted columns lack protected disposition: #{misplaced.sort.join(',')}" if misplaced.any?

    true
  end

  def extract_item(record)
    extract(record, :item)
  end

  def extract_account(record)
    extract(record, :account)
  end

  def authorization_fields
    provider_key == "enable_banking" ? AUTHORIZATION_FIELDS : []
  end

  def authorization_required?
    provider_key == "enable_banking"
  end

  def inspect
    "#<#{self.class.name} provider=#{provider_key} version=#{VERSION}>"
  end

  private
    def extract(record, kind)
      expected_table = kind == :item ? item_table : account_table
      unless record.class.table_name == expected_table
        raise InvalidSource, "Unexpected source table for #{provider_key} #{kind}"
      end

      source_columns = record.class.columns_hash
      encrypted = record.class.respond_to?(:encrypted_attributes) ? record.class.encrypted_attributes : []
      validate_columns!(kind, source_columns.keys, encrypted_columns: encrypted || [])
      column_metadata = source_columns.to_h { |name, column| [ name, describe_column(column) ] }

      buckets = BUCKETS.to_h do |bucket|
        values = Array(dispositions(kind)[bucket]).to_h do |column|
          # read_attribute uses ActiveRecord's declared type, serializer and
          # decryptor (including previous encryption schemes). Custom readers
          # such as Syncable#last_synced_at must not replace persisted values.
          value = record.read_attribute(column)
          if PROTECTED_BUCKETS.include?(bucket) && value.is_a?(String) &&
              defined?(ActiveRecord::Encryption) && ActiveRecord::Encryption.encryptor.encrypted?(value)
            # Legacy encrypts declarations are conditional at model load. An
            # undecoded encrypted message must not be treated as a plaintext
            # credential just because the new target encryptor is available.
            raise InvalidSource, "Encrypted source column was not decoded: #{column}"
          end
          [ column, self.class.copy_value(value) ]
        end
        [ bucket, values.freeze ]
      end
      source_attributes = buckets.values.reduce({}) { |result, values| result.merge(values) }
      components = kind == :account ? IDENTITIES.fetch(provider_key).to_h { |key| [ key, source_attributes.fetch(key) ] } : {}

      Projection.new(
        provider_key: provider_key, kind: kind, source_table: expected_table,
        source_type: kind == :item ? item_type : account_type,
        buckets: buckets, column_metadata: column_metadata,
        identity_components: components,
        external_id: kind == :account ? external_identity(components) : nil
      )
    end

    def describe_column(column)
      type = column.type.to_sym
      raise InvalidSource, "Unsupported source column type #{type}" unless SOURCE_TYPES.include?(type)
      if type == :decimal && (column.precision.to_i > 38 || column.scale.to_i > 18)
        raise InvalidSource, "Source decimal exceeds shared storage precision"
      end

      self.class.copy_value({
        "type" => type.to_s, "null" => column.null,
        "default" => column.default, "precision" => column.precision,
        "scale" => column.scale,
        "default_function" => column.respond_to?(:default_function) ? column.default_function : nil,
        "array" => column.respond_to?(:array) ? column.array : false
      })
    end

    def external_identity(components)
      required = components.keys
      required -= [ "wallet_address" ] if provider_key == "coinstats"
      if provider_key == "onchain_wallet" && components["asset_kind"] == "native"
        required -= [ "contract_address" ]
      end
      return nil if required.any? { |key| components[key].nil? || components[key].to_s.empty? }
      unless components.values.compact.all? { |value| value.is_a?(String) }
        raise InvalidSource, "Source account identity components must be strings"
      end

      return components.values.first.dup if components.size == 1

      # JSON arrays avoid separator collisions and retain null component values.
      # Never case-fold chain addresses, trim upstream IDs or use session tokens.
      JSON.generate(components.to_a)
    end
end
