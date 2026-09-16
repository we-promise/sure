module ProviderDataOwnership
  extend ActiveSupport::Concern

  private
    def validate_family_of(record, attribute)
      return if record.nil? || record.family_id == family_id

      errors.add(attribute, "must belong to the same family")
    end

    def validate_connection_of(record, attribute)
      validate_family_of(record, attribute)
      return if record.nil? || record.provider_connection_id == provider_connection_id

      errors.add(attribute, "must belong to the same provider connection")
    end

    def validate_documents(*attributes)
      attributes.each do |attribute|
        errors.add(attribute, "must be an object") unless public_send(attribute).is_a?(Hash)
      end
    end
end
