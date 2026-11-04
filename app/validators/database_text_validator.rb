# EachValidator calls blank? before validate_each, which raises for malformed UTF-8.
class DatabaseTextValidator < ActiveModel::Validator
  def self.acceptable?(value)
    case value
    when String then value.valid_encoding? && !value.include?("\0")
    when Array then value.all? { |item| acceptable?(item) }
    when Hash then value.all? { |key, item| acceptable?(key) && acceptable?(item) }
    else true
    end
  end

  def validate(record)
    options.fetch(:attributes).each do |attribute|
      value = record.public_send(attribute)
      next if self.class.acceptable?(value)

      record.errors.add(attribute, :invalid)
    end
  end
end
