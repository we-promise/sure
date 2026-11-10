# Compatibility for Rails #58865 / proposed fix #58866.
# Remove only after the replacement Rails version passes the regression tests.
# No stored values or installed gem files are changed.
module NormalizedEncryptionCompatibility
  SUPPORTED_VERSION = "8.1.3.1".freeze
  Query = ActiveRecord::Encryption::ExtendedDeterministicQueries

  module NormalizedCast
    # Return query markers unchanged so normalization never casts ciphertext as text.
    def cast(value)
      value.is_a?(Query::AdditionalValue) ? value : super
    end
  end

  module PreviousQueryValues
    private
      # Normalize plaintext before serializing predicates for earlier schemes.
      def additional_values_for(value, type)
        super(type.cast(value), type)
      end
  end

  module PreviousUniquenessValues
    # Validate current and previous ciphertext predicates through the base validator.
    # Previous values are already serialized and must not be encrypted a second time.
    def validate_each(record, attribute, value)
      super(record, attribute, value)

      klass = record.class
      if klass.deterministic_encrypted_attributes&.include?(attribute)
        encrypted_type = klass.type_for_attribute(attribute)
        encrypted_type.previous_types.each do |type|
          encrypted_value = Query::AdditionalValue.new(value, type)
          ActiveRecord::Encryption.without_encryption do
            super(record, attribute, encrypted_value)
          end
        end
      end
    end
  end

  # Install the compatibility hooks once, rejecting unqualified Rails versions.
  # Replacing the validator extension preserves its original super dispatch.
  def self.install!
    unless ActiveRecord.version.to_s == SUPPORTED_VERSION
      raise "Requalify normalized encryption compatibility before changing Rails #{SUPPORTED_VERSION}"
    end
    return if @installed

    ActiveModel::Attributes::Normalization::NormalizedValueType.prepend(NormalizedCast)
    Query::EncryptedQuery.singleton_class.prepend(PreviousQueryValues)
    ActiveRecord::Encryption::EncryptedAttributeType.prepend(Query::ExtendedEncryptableType)

    # Replacing this extension method preserves super's base-validator dispatch.
    # Prepending another validator would also run the defective Rails extension.
    target = ActiveRecord::Encryption::ExtendedDeterministicUniquenessValidator::EncryptedUniquenessValidator
    target.define_method(:validate_each, PreviousUniquenessValues.instance_method(:validate_each))
    @installed = true
  end
end
