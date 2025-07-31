require 'digest'

class SignatureValidator
  Error = Class.new(StandardError)

  def initialize(secret_key)
    @secret_key = secret_key
  end

  def validate_webhook!(request_body, signature)
    expected_signature = generate_signature(request_body)
    
    unless ActiveSupport::SecurityUtils.secure_compare(signature, expected_signature)
      raise Error, "Invalid signature"
    end
  end

  private
    attr_reader :secret_key

    # Flatten nested objects (hashes/arrays)
    def flatten_object(obj, path = [])
      return [[path.join, obj]] unless obj.is_a?(Hash) || obj.is_a?(Array)

      flat_entries = []
      obj.each_with_index do |(key, value), index|
        new_key = if obj.is_a?(Array)
                    "#{path.join}[#{index}]"
                  else
                    path.empty? ? key.to_s : "#{path.join}.#{key}"
                  end
        flat_entries += flatten_object(value, [new_key])
      end
      flat_entries
    end

    # Build query string from flattened hash
    def object_to_query_string(obj)
      # Remove the signature field if present for validation
      obj_without_signature = obj.except('signature', :signature)
      
      flat_entries = flatten_object(obj_without_signature).reject { |_, v| v.nil? }
      flat_entries.sort_by! { |k, _| k.downcase }
      flat_entries.map { |k, v| "#{k}=#{v}" }.join("&")
    end

    def generate_signature(request_body)
      flat_string = object_to_query_string(request_body)
      Digest::SHA256.hexdigest(flat_string)
    end
end