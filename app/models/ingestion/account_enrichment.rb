# Called under the connection fence and linked-account lock. This allowlist
# constrains provider hints to fields on the existing trusted domain object;
# metadata never selects a Ruby class or creates/replaces an accountable.
class Ingestion::AccountEnrichment
  LIABILITY_FIELDS = {
    "CreditCard" => %w[minimum_payment apr],
    "Loan" => %w[rate_type interest_rate initial_balance term_months]
  }.transform_values(&:freeze).freeze
  STRATEGIES = %w[enrich update update_non_null].freeze

  def initialize(account:, source:)
    @account, @source = account, source
  end

  def apply!(metadata:)
    values = object(metadata)
    identity_hint = optional_object(values[:account_enrichment])
    liability_hint = optional_object(values[:accountable_attributes])
    identity = validate_identity(identity_hint) if identity_hint
    liability = validate_liability(liability_hint) if liability_hint
    # Validate both structures before any enrichment can be logged or saved.
    if identity
      enrich!(@account, identity.slice(:name))
      enrich!(@account.accountable, identity.slice(:subtype))
    end
    if liability
      attributes = liability.fetch(:attributes)
      case liability.fetch(:strategy)
      when "enrich" then enrich!(@account.accountable, attributes)
      when "update" then @account.accountable.update!(attributes)
      when "update_non_null" then @account.accountable.update!(attributes.compact) if attributes.compact.any?
      end
    end
  rescue ArgumentError, KeyError, TypeError, NoMethodError
    raise Provider::AccountData::InvalidResponse, "Invalid account enrichment hints", cause: nil
  end

  private
    def object(value)
      raise ArgumentError unless value.is_a?(Hash)
      value.with_indifferent_access
    end

    def optional_object(value)
      return if value.nil?
      values = object(value)
      values unless values.empty?
    end

    def validate_type!(type)
      unless Accountable::TYPES.include?(type) && @account.accountable_type == type && @account.accountable&.class&.name == type
        raise ArgumentError
      end
    end

    def validate_identity(value)
      values = object(value)
      raise ArgumentError unless (values.keys - %w[accountable_type name subtype]).empty?
      validate_type!(values.fetch(:accountable_type))
      %i[name subtype].each do |field|
        next unless values.key?(field)
        raise ArgumentError unless values[field].is_a?(String) && values[field].present?
      end
      values
    end

    def validate_liability(value)
      values = object(value)
      raise ArgumentError unless values.keys.sort == %w[accountable_type attributes strategy]
      type = values.fetch(:accountable_type)
      validate_type!(type)
      raise ArgumentError unless STRATEGIES.include?(values.fetch(:strategy))
      attributes = object(values.fetch(:attributes))
      raise ArgumentError unless (attributes.keys - LIABILITY_FIELDS.fetch(type)).empty?
      attributes.each do |key, item|
        next if item.nil?
        case key
        when "rate_type" then raise ArgumentError unless item.is_a?(String) && item.present? && item.bytesize <= 64
        when "term_months" then raise ArgumentError unless item.is_a?(Integer)
        else raise ArgumentError unless item.is_a?(BigDecimal) && item.finite?
        end
      end
      values.merge(attributes: attributes)
    end

    def enrich!(record, attributes)
      return if attributes.empty?
      record.enrich_attributes(attributes, source: @source)
      # Enrichable intentionally returns false for both no change and a failed
      # save. A failed validation must roll back its logged enrichment as well.
      record.save! if record.changed? || record.errors.any?
    end
end
