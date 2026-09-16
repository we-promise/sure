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
  POLL_INTERVAL = 3
  MAX_POLL_ATTEMPTS = 20
  PENDING_ERROR_CODES = %w[1004 1019].freeze

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

  def download_statement
    reference_code = request_reference_code
    poll_statement(reference_code)
  end

  # Native ingestion performs one physical request at a time. The coordinator
  # persists the encrypted reference and schedules a later poll; no worker sleeps.
  def request_statement_page
    response, document = native_response("/SendRequest", query_id)
    native_response_error!(document, response)
    reference = document.at_xpath("/FlexStatementResponse/ReferenceCode")&.text.to_s.strip
    validate_native_reference!(reference)
    { status: "requested", reference: reference, evidence: { "response_xml" => response.body } }
  end

  def poll_statement_page(reference:)
    validate_native_reference!(reference)
    response, document = native_response("/GetStatement", reference)
    if response.success? && document.root&.name == "FlexQueryResponse"
      return { status: "ready", reference: reference, xml: response.body, evidence: { "response_xml" => response.body } }
    end
    code = document.at_xpath("/FlexStatementResponse/ErrorCode")&.text.to_s.strip
    if response.success? && PENDING_ERROR_CODES.include?(code)
      return { status: "pending", reference: reference, evidence: { "response_xml" => response.body } }
    end
    native_response_error!(document, response)
    raise ApiError, "IBKR Flex returned an unexpected statement response"
  end

  private

    def validate_native_reference!(reference)
      unless reference.is_a?(String) && reference.match?(/\A[A-Za-z0-9_-]{1,256}\z/)
        raise ApiError, "IBKR Flex returned an invalid statement reference"
      end
    end

    def native_response(path, reference)
      response = self.class.get(path, query: { t: token, q: reference, v: 3 }, follow_redirects: false)
      if [ 401, 403 ].include?(response.code.to_i)
        raise AuthenticationError, "IBKR Flex authentication failed"
      end
      body = response.body
      unless body.is_a?(String) && body.bytesize <= 32 * 1024 * 1024 && !body.match?(/<!DOCTYPE/i)
        raise ApiError, "IBKR Flex returned an invalid or oversized XML response"
      end
      document = Nokogiri::XML(body) { |config| config.strict.nonet.noblanks }
      unless %w[FlexStatementResponse FlexQueryResponse].include?(document.root&.name)
        raise ApiError, "IBKR Flex returned an unexpected XML root"
      end
      [ response, document ]
    rescue Nokogiri::XML::SyntaxError, *RETRYABLE_ERRORS
      raise ApiError, "IBKR Flex statement request failed", cause: nil
    end

    def native_response_error!(document, response)
      code = document.at_xpath("/FlexStatementResponse/ErrorCode")&.text.to_s.strip
      status = document.at_xpath("/FlexStatementResponse/Status")&.text.to_s.strip
      return if response.success? && code.empty? && status == "Success"
      case code
      when "1012", "1015"
        raise AuthenticationError, "IBKR Flex authentication failed"
      when "1014"
        raise ConfigurationError, "IBKR Flex query configuration is invalid"
      else
        raise ApiError.new("IBKR Flex request failed", status_code: response.code, error_code: code.presence)
      end
    end

    def request_reference_code
      response = with_retries("SendRequest") do
        self.class.get("/SendRequest", query: { t: token, q: query_id, v: 3 })
      end

      xml = parse_xml(response.body)
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
        response = with_retries("GetStatement") do
          self.class.get("/GetStatement", query: { t: token, q: reference_code, v: 3 })
        end

        xml = parse_xml(response.body)
        return response.body if xml.at_xpath("//FlexQueryResponse")

        error = response_error(xml, response)
        if error.is_a?(ApiError) && PENDING_ERROR_CODES.include?(error.error_code.to_s)
          raise ApiError.new("IBKR Flex statement is still being generated.", error_code: error.error_code) if attempts >= MAX_POLL_ATTEMPTS

          sleep(POLL_INTERVAL)
          next
        end

        raise(error || ApiError.new("IBKR Flex returned an unexpected response.", status_code: response.code, response_body: response.body))
      end
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
