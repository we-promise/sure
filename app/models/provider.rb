class Provider
  Response = Data.define(:success?, :data, :error)

  class Error < StandardError
    attr_reader :details, :failure_code

    # Builds a provider error. `details` holds opaque response metadata
    # (e.g. the upstream body); `failure_code` is an optional symbol the
    # admin AI status page and health probe key on so they can show a
    # specific, actionable reason instead of a generic message.
    def initialize(message, details: nil, failure_code: nil)
      super(message)
      @details = details
      @failure_code = failure_code
    end

    # Serialized form for API consumers. Includes `failure_code` so
    # downstream UI can branch on the reason rather than the message text.
    def as_json
      {
        message: message,
        details: details,
        failure_code: failure_code
      }
    end
  end

  private
    PaginatedData = Data.define(:paginated, :first_page, :total_pages)
    UsageData = Data.define(:used, :limit, :utilization, :plan)

    def with_provider_response(error_transformer: nil, &block)
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
    end

    # Fallback transformation applied by `with_provider_response` when no
    # `error_transformer:` is given. Re-wraps an arbitrary rescue into a
    # `self.class::Error`, carrying over the error's `failure_code` (when
    # present and truthy) and, for Faraday errors, the response body as
    # `details`. Subclasses may override this to customise.
    def default_error_transformer(error)
      kwargs = if error.respond_to?(:failure_code) && error.failure_code
        { failure_code: error.failure_code }
      else
        {}
      end

      if error.is_a?(Faraday::Error)
        self.class::Error.new(
          error.message,
          details: error.response&.dig(:body),
          **kwargs
        )
      else
        self.class::Error.new(error.message, **kwargs)
      end
    end
end
