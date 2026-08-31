class Provider
  Response = Data.define(:success?, :data, :error)

  class Error < StandardError
    attr_reader :details, :failure_code

    def initialize(message, details: nil, failure_code: nil)
      super(message)
      @details = details
      @failure_code = failure_code
    end

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

    # Override to set class-level error transformation for methods using `with_provider_response`
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
