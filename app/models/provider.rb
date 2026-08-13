class Provider
  Response = Data.define(:success?, :data, :error)

  class Error < StandardError
    attr_reader :details

    def initialize(message, details: nil)
      super(message)
      @details = details
    end

    def as_json
      {
        message: message,
        details: details
      }
    end
  end

  private
    PaginatedData = Data.define(:paginated, :first_page, :total_pages)
    UsageData = Data.define(:used, :limit, :utilization, :plan)

    def with_provider_response(error_transformer: nil, debug_log: nil, &block)
      data = yield

      Response.new(
        success?: true,
        data: data,
        error: nil,
      )
    rescue => error
      transformed_error = if error_transformer
        error_transformer.call(error)
      else
        default_error_transformer(error)
      end

      Response.new(
        success?: false,
        data: nil,
        error: transformed_error
      )
    ensure
      capture_provider_debug_log(debug_log, error, transformed_error) if defined?(error) && error
    end

    # Override to set class-level error transformation for methods using `with_provider_response`
    def default_error_transformer(error)
      if error.is_a?(Faraday::Error)
        self.class::Error.new(
          error.message,
          details: error.response&.dig(:body),
        )
      else
        self.class::Error.new(error.message)
      end
    end

    def capture_provider_debug_log(debug_log, original_error, transformed_error)
      return if debug_log.blank?

      provider_error = transformed_error || original_error
      attributes = debug_log.respond_to?(:call) ? debug_log.call(original_error, provider_error) : debug_log
      attributes = attributes.to_h.symbolize_keys
      metadata = (attributes[:metadata] || {}).merge(provider_error_metadata(original_error, provider_error))

      DebugLogEntry.capture(
        category: attributes.fetch(:category, "provider_error"),
        level: attributes.fetch(:level, "error"),
        message: attributes[:message].presence || "#{self.class.name} request failed: #{safe_provider_error_message(provider_error)}",
        source: attributes.fetch(:source, self.class.name),
        provider_key: attributes[:provider_key],
        family: attributes[:family],
        family_id: attributes[:family_id],
        account: attributes[:account],
        account_id: attributes[:account_id],
        user: attributes[:user],
        user_id: attributes[:user_id],
        account_provider: attributes[:account_provider],
        account_provider_id: attributes[:account_provider_id],
        metadata: metadata.compact
      )
    rescue => capture_error
      Rails.logger.error("Provider debug log capture failed: #{capture_error.class}: #{capture_error.message}")
    end

    def provider_error_metadata(original_error, provider_error)
      {
        error_class: original_error.class.name,
        provider_error_class: provider_error.class.name,
        error_message: safe_provider_error_message(provider_error),
        http_status_code: provider_http_status_code(original_error) || provider_http_status_code(provider_error),
        details: provider_error.respond_to?(:details) ? sanitized_provider_debug_value(provider_error.details) : nil
      }
    end

    def provider_http_status_code(error)
      if error.respond_to?(:status)
        error.status
      elsif error.respond_to?(:http_status)
        error.http_status
      elsif error.respond_to?(:response)
        response = error.response
        response[:status] if response.respond_to?(:[])
      elsif safe_provider_error_message(error) =~ /\b([1-5]\d{2})\b/
        $1.to_i
      end
    rescue
      nil
    end

    def sanitized_provider_debug_value(value)
      case value
      when Hash
        value.each_with_object({}) do |(key, nested_value), sanitized|
          key_string = key.to_s
          sanitized[key_string] = sensitive_debug_key?(key_string) ? "[FILTERED]" : sanitized_provider_debug_value(nested_value)
        end
      when Array
        value.map { |nested_value| sanitized_provider_debug_value(nested_value) }
      when String
        value.truncate(1_000)
      when NilClass, Numeric, TrueClass, FalseClass
        value
      else
        value.to_s.truncate(1_000)
      end
    end

    def sensitive_debug_key?(key)
      key.match?(/token|secret|password|authorization|api[_-]?key|credential/i)
    end

    def safe_provider_error_message(error)
      error&.message
    rescue => message_error
      "(message unavailable: #{message_error.class})"
    end
end
