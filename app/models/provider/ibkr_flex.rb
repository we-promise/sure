class Provider::IbkrFlex
  include HTTParty
  extend SslConfigurable

  class Error < StandardError; end
  class AuthenticationError < Error; end
  class ConfigurationError < Error; end
  class ApiError < Error
    attr_reader :status_code, :response_body, :error_code

    def initialize(message, status_code: nil, response_body: nil, error_code: nil)
      super(message)
      @status_code = status_code
      @response_body = response_body
      @error_code = error_code
    end
  end

  base_uri "https://ndcdyn.interactivebrokers.com/AccountManagement/FlexWebService"
  headers "User-Agent" => "Sure Finance IBKR Flex Client"
  default_options.merge!({ timeout: 120 }.merge(httparty_ssl_options))

  MAX_RETRIES = 3
  INITIAL_RETRY_DELAY = 2
  MAX_RETRY_DELAY = 30
  MAX_POLL_ATTEMPTS = 20
  PENDING_ERROR_CODES = %w[1004 1019].freeze
  # IBKR allows 10 requests a minute per token, so polling waits REQUEST_INTERVAL
  # (20 attempts, no less time than before). 1018 says that limit was hit,
  # 1001 and 1009 that the server is busy: all three mean "try again shortly".
  REQUEST_INTERVAL = 6
  THROTTLED_ERROR_CODES = %w[1001 1009 1018].freeze
  THROTTLE_RETRY_DELAY = 10
  MAX_THROTTLE_RETRIES = 3

  RETRYABLE_ERRORS = [
    SocketError,
    Net::OpenTimeout,
    Net::ReadTimeout,
    Errno::ECONNRESET,
    Errno::ECONNREFUSED,
    Errno::ETIMEDOUT,
    EOFError
  ].freeze

  attr_reader :query_id, :token

  def initialize(query_id:, token:)
    raise ConfigurationError, "query_id is required" if query_id.blank?
    raise ConfigurationError, "token is required" if token.blank?

    @query_id = query_id.to_s.strip
    @token = token.to_s.strip
  end

  # Without dates IBKR uses the period saved on the query; fd/td (yyyymmdd)
  # ask for that range instead, at most 365 days.
  def download_statement(from_date: nil, to_date: nil)
    query = { t: token, q: query_id, v: 3 }
    query.merge!(fd: from_date.strftime("%Y%m%d"), td: to_date.strftime("%Y%m%d")) if from_date

    reference_code = request_reference_code(query)
    poll_statement(reference_code)
  end

  private

    def request_reference_code(query)
      response, xml = flex_get("SendRequest", query)
      error = response_error(xml, response)
      raise error if error

      reference_code = xml.at_xpath("//ReferenceCode")&.text.to_s.strip
      raise ApiError.new("IBKR Flex did not return a reference code.", status_code: response.code, response_body: response.body) if reference_code.blank?

      reference_code
    end

    def poll_statement(reference_code)
      attempts = 0

      loop do
        attempts += 1
        response, xml = flex_get("GetStatement", { t: token, q: reference_code, v: 3 })
        return response.body if xml.at_xpath("//FlexQueryResponse")

        error = response_error(xml, response)
        if error.is_a?(ApiError) && PENDING_ERROR_CODES.include?(error.error_code.to_s)
          raise ApiError.new("IBKR Flex statement is still being generated.", error_code: error.error_code) if attempts >= MAX_POLL_ATTEMPTS

          next
        end

        raise(error || ApiError.new("IBKR Flex returned an unexpected response.", status_code: response.code, response_body: response.body))
      end
    end

    # Every call, network retries included, is spaced REQUEST_INTERVAL from
    # the previous one, which also paces the polling, and retried a few times
    # while IBKR is throttling.
    def flex_get(operation, query)
      throttled = 0
      loop do
        response = with_retries(operation) do
          wait_for_request_slot
          self.class.get("/#{operation}", query: query)
        end
        xml = parse_xml(response.body)
        return [ response, xml ] unless THROTTLED_ERROR_CODES.include?(xml.at_xpath("//ErrorCode")&.text.to_s.strip) && throttled < MAX_THROTTLE_RETRIES

        throttled += 1
        sleep(THROTTLE_RETRY_DELAY)
      end
    end

    def wait_for_request_slot
      wait = @last_request_at && @last_request_at + REQUEST_INTERVAL - Process.clock_gettime(Process::CLOCK_MONOTONIC)
      sleep(wait) if wait&.positive?
      @last_request_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def response_error(xml, response)
      error_code = xml.at_xpath("//ErrorCode")&.text.to_s.strip.presence
      error_message = xml.at_xpath("//ErrorMessage")&.text.to_s.strip.presence

      return nil if error_code.blank? && response.success?

      message = error_message.presence || "IBKR Flex request failed"

      case error_code
      when "1012", "1015"
        AuthenticationError.new(message)
      when "1014"
        ConfigurationError.new(message)
      else
        ApiError.new(message, status_code: response.code, response_body: response.body, error_code: error_code)
      end
    end

    def parse_xml(body)
      Nokogiri::XML(body.to_s)
    end

    def with_retries(operation_name, max_retries: MAX_RETRIES)
      retries = 0

      begin
        yield
      rescue *RETRYABLE_ERRORS => e
        retries += 1

        if retries <= max_retries
          delay = calculate_retry_delay(retries)
          Rails.logger.warn(
            "IBKR Flex: #{operation_name} failed (attempt #{retries}/#{max_retries}): #{e.class}: #{e.message}. Retrying in #{delay}s..."
          )
          sleep(delay)
          retry
        end

        raise ApiError.new("Network error after #{max_retries} retries: #{e.message}")
      end
    end

    def calculate_retry_delay(retry_count)
      base_delay = INITIAL_RETRY_DELAY * (2**(retry_count - 1))
      jitter = base_delay * rand * 0.25
      [ base_delay + jitter, MAX_RETRY_DELAY ].min
    end
end
