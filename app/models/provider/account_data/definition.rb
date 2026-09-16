class Provider::AccountData::Definition
  CAPABILITIES = %w[transactions holdings activities].freeze
  SCOPES = %w[connection application].freeze
  TYPES = %w[string text integer boolean].freeze

  attr_reader :key, :source, :credential_scope, :fields, :capabilities

  def initialize(key:, source:, credential_scope:, fields:, capabilities:)
    unless [ key, source ].all? { |value| value.is_a?(String) && value.match?(/\A[a-z][a-z0-9]*(?:_[a-z0-9]+)*\z/) }
      raise ArgumentError, "key and source must be stable snake_case identifiers"
    end
    raise ArgumentError, "unknown credential scope" unless SCOPES.include?(credential_scope)
    unless capabilities.is_a?(Array) && (capabilities - CAPABILITIES).empty? && capabilities.uniq == capabilities
      raise ArgumentError, "unknown or duplicate capabilities"
    end
    validate_fields!(fields)

    @key = key.dup.freeze
    @source = source.dup.freeze
    @credential_scope = credential_scope.dup.freeze
    @fields = fields.map { |field| field.transform_values { |v| v.is_a?(String) ? v.dup.freeze : v }.freeze }.freeze
    @capabilities = capabilities.map { |value| value.dup.freeze }.freeze
    freeze
  end

  def supports?(capability)
    capabilities.include?(capability.to_s)
  end

  private
    def validate_fields!(fields)
      raise ArgumentError, "fields must be an array" unless fields.is_a?(Array)

      names = fields.map do |field|
        unless field.is_a?(Hash) && (field.keys - %i[name type secret default]).empty? &&
            field[:name].is_a?(String) && field[:name].match?(/\A[a-z][a-z0-9]*(?:_[a-z0-9]+)*\z/) &&
            TYPES.include?(field[:type]) && [ true, false ].include?(field[:secret])
          raise ArgumentError, "invalid field definition"
        end

        value = field[:default]
        raise ArgumentError, "secret fields cannot have defaults" if field[:secret] && !value.nil?
        valid = value.nil? || case field[:type]
        when "integer" then value.is_a?(Integer)
        when "boolean" then [ true, false ].include?(value)
        else value.is_a?(String)
        end
        raise ArgumentError, "default must match field type" unless valid
        field[:name]
      end
      raise ArgumentError, "duplicate fields" unless names.uniq == names
    end
end
