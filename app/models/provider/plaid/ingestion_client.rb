require "json"
require "bigdecimal"

# Use the installed SDK's authenticated transport but request the original JSON
# string. SDK response models convert monetary fields to Float before callers
# can normalize them. This reader never invokes legacy snapshot/import code.
class Provider::Plaid::IngestionClient
  class Error < StandardError
    attr_reader :error_code

    def initialize(error_code)
      @error_code = error_code
      super("Plaid account read failed")
    end
  end

  MAX_RESPONSE_BYTES = 20.megabytes
  MAX_ROWS = 20_000
  COUNT = 500
  ERROR_CODES = %w[ITEM_LOGIN_REQUIRED INVALID_ACCESS_TOKEN INVALID_API_KEYS PRODUCT_NOT_READY
    TRANSACTIONS_SYNC_MUTATION_DURING_PAGINATION ADDITIONAL_CONSENT_REQUIRED ITEM_NOT_SUPPORTED
    INVALID_CURSOR RATE_LIMIT_EXCEEDED INSTITUTION_DOWN INTERNAL_SERVER_ERROR].freeze

  def initialize(api_client:, access_token:, region:)
    unless access_token.is_a?(String) && access_token.present? && %w[us eu].include?(region)
      raise ArgumentError, "Plaid requires an item token and explicit region"
    end
    raise ArgumentError, "Plaid SDK debugging must be disabled" if api_client.config.debugging
    @api_client, @access_token, @region = api_client, access_token, region
  end

  def get_item
    read("/item/get").tap do |value|
      item = object(value.fetch(:item))
      if item[:error]
        failure = object(item[:error])
        raise Error.new(ERROR_CODES.include?(failure[:error_code]) ? failure[:error_code] : "API_ERROR")
      end
    end
  rescue ArgumentError, KeyError, TypeError
    raise Error.new("INVALID_RESPONSE"), cause: nil
  end

  def get_accounts
    collection(read("/accounts/get"), :accounts)
  end

  def get_institution(institution_id:)
    id = identifier(institution_id)
    countries = @region == "eu" ? %w[ES NL FR IE DE IT PL DK NO SE EE LT LV PT BE] : %w[US CA]
    read("/institutions/get_by_id", { institution_id: id, country_codes: countries, options: { include_optional_metadata: true } }, item: false)
      .tap { |value| object(value.fetch(:institution)) }
  rescue ArgumentError, KeyError, TypeError
    raise Error.new("INVALID_RESPONSE"), cause: nil
  end

  def get_transactions_page(cursor: nil)
    check_cursor(cursor)
    params = { count: COUNT, options: { include_original_description: true } }
    params[:cursor] = cursor unless cursor.nil?
    value = read("/transactions/sync", params)
    %i[added modified removed].each { |key| collection(value, key) }
    raise ArgumentError unless [ true, false ].include?(value[:has_more]) && value[:next_cursor].is_a?(String) && value[:next_cursor].present?
    check_cursor(value[:next_cursor])
    raise ArgumentError if value[:has_more] && value[:next_cursor] == cursor
    raise ArgumentError if %i[added modified removed].sum { |key| value[key].size } > COUNT
    value
  rescue ArgumentError, KeyError, TypeError
    raise Error.new("INVALID_RESPONSE"), cause: nil
  end

  def get_holdings(account_id: nil)
    params = account_id ? { options: { account_ids: [ identifier(account_id) ] } } : {}
    value = read("/investments/holdings/get", params)
    %i[holdings securities accounts].each { |key| collection(value, key) }
    value
  end

  def get_investment_transactions_page(start_date:, end_date:, offset: 0, account_id: nil)
    raise ArgumentError unless start_date.instance_of?(Date) && end_date.instance_of?(Date) && start_date <= end_date && offset.is_a?(Integer) && offset >= 0
    options = { offset: offset, count: COUNT }
    options[:account_ids] = [ identifier(account_id) ] if account_id
    value = read("/investments/transactions/get", { start_date: start_date.iso8601, end_date: end_date.iso8601, options: options })
    %i[investment_transactions securities accounts].each { |key| collection(value, key) }
    total = value[:total_investment_transactions]
    count = value[:investment_transactions].size
    raise ArgumentError unless total.is_a?(Integer) && total >= 0 && count <= COUNT && offset + count <= total
    raise ArgumentError if count.zero? && offset < total
    value
  rescue ArgumentError, KeyError, TypeError
    raise Error.new("INVALID_RESPONSE"), cause: nil
  end

  def get_liabilities(account_id: nil)
    params = account_id ? { options: { account_ids: [ identifier(account_id) ] } } : {}
    value = read("/liabilities/get", params)
    liabilities = object(value.fetch(:liabilities))
    %i[credit mortgage student].each { |key| collection(liabilities, key) unless liabilities[key].nil? }
    value
  rescue ArgumentError, KeyError, TypeError
    raise Error.new("INVALID_RESPONSE"), cause: nil
  end

  def inspect
    "#<#{self.class.name}>"
  end

  private
    def read(path, parameters = {}, item: true)
      raise ArgumentError if @api_client.config.debugging
      body = parameters.deep_dup
      body[:access_token] = @access_token if item
      raw, status, = @api_client.call_api(:POST, path,
        header_params: { "Accept" => "application/json", "Content-Type" => "application/json" },
        query_params: {}, form_params: {}, body: JSON.generate(body),
        auth_names: %w[clientId plaidVersion secret], return_type: "String")
      raise ArgumentError unless status == 200 && raw.is_a?(String) && raw.bytesize <= MAX_RESPONSE_BYTES
      object(JSON.parse(raw, decimal_class: BigDecimal))
    rescue ::Plaid::ApiError => error
      code = begin
        raw_error = error.response_body.to_s
        raise JSON::ParserError if raw_error.bytesize > MAX_RESPONSE_BYTES
        value = JSON.parse(raw_error)
        value.is_a?(Hash) && ERROR_CODES.include?(value["error_code"]) ? value["error_code"] : "API_ERROR"
      rescue JSON::ParserError
        "API_ERROR"
      end
      # SDK exceptions carry request IDs, headers and private response bodies.
      raise Error.new(code), cause: nil
    rescue ArgumentError, JSON::ParserError, KeyError, TypeError
      raise Error.new("INVALID_RESPONSE"), cause: nil
    end

    def object(value)
      raise ArgumentError unless value.is_a?(Hash)
      value.with_indifferent_access
    end

    def collection(value, key)
      rows = value[key]
      raise Error.new("INVALID_RESPONSE") unless rows.is_a?(Array) && rows.size <= MAX_ROWS && rows.all? { |row| row.is_a?(Hash) }
      value
    end

    def identifier(value)
      raise ArgumentError unless value.is_a?(String) && value.present?
      value
    end

    def check_cursor(value)
      raise ArgumentError unless value.nil? || (value.is_a?(String) && value.present? && value != "now" && value.bytesize <= 256)
    end
end
