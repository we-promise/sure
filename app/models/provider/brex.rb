# frozen_string_literal: true

class Provider::Brex
  include HTTParty
  extend SslConfigurable

  DEFAULT_BASE_URL = "https://api.brex.com"
  STAGING_BASE_URL = "https://api-staging.brex.com"
  ALLOWED_BASE_URLS = [ DEFAULT_BASE_URL, STAGING_BASE_URL ].freeze
  DEFAULT_LIMIT = 1000
  # Transaction syncs are date-window bounded; this is only a runaway cursor guard.
  MAX_PAGES = 25

  headers "User-Agent" => "Sure Finance Brex Client"
  default_options.merge!({ timeout: 120 }.merge(httparty_ssl_options))

  attr_reader :token, :base_url

  def initialize(token, base_url: DEFAULT_BASE_URL)
    @token = token.to_s.strip
    @base_url = self.class.normalize_base_url(base_url)
    raise ArgumentError, "Brex base URL must be blank or one of: #{ALLOWED_BASE_URLS.join(', ')}" unless @base_url.present?
  end

  def self.normalize_base_url(value)
    stripped = value.to_s.strip
    return DEFAULT_BASE_URL if stripped.blank?

    uri = URI.parse(stripped)
    return nil unless uri.is_a?(URI::HTTPS)
    return nil if uri.userinfo.present?
    return nil if uri.query.present? || uri.fragment.present?
    return nil unless uri.path.blank? || uri.path == "/"
    return nil unless uri.port == 443

    # This exact allowlist is the SSRF boundary; arbitrary Brex-like hosts are never accepted.
    normalized = "#{uri.scheme.downcase}://#{uri.host.to_s.downcase}"
    ALLOWED_BASE_URLS.include?(normalized) ? normalized : nil
  rescue URI::InvalidURIError
    nil
  end

  def self.allowed_base_url?(value)
    normalize_base_url(value).present?
  end

  def get_accounts
    cash_accounts = get_cash_accounts
    card_accounts = get_card_accounts

    accounts = cash_accounts.dup
    accounts << aggregate_card_account(card_accounts) if card_accounts.any?

    {
      accounts: accounts,
      cash_accounts: cash_accounts,
      card_accounts: card_accounts
    }
  end

  def get_cash_accounts
    get_paginated("/v2/accounts/cash").map { |account| account.with_indifferent_access.merge(account_kind: "cash") }
  end

  def get_card_accounts
    get_paginated("/v2/accounts/card").map { |account| account.with_indifferent_access.merge(account_kind: "card") }
  end

  def get_cash_transactions(account_id, start_date: nil)
    path = "/v2/transactions/cash/#{ERB::Util.url_encode(account_id.to_s)}"
    {
      transactions: get_paginated(path, params: posted_at_start_params(start_date))
    }
  end

  def get_primary_card_transactions(start_date: nil)
    {
      transactions: get_paginated("/v2/transactions/card/primary", params: posted_at_start_params(start_date))
    }
  end

  private

    def aggregate_card_account(card_accounts)
      totals = %i[current_balance available_balance account_limit].index_with do |field|
        sum_money(card_accounts.filter_map { |account| account.with_indifferent_access[field] })
      end

      {
        id: BrexAccount.card_account_id,
        name: "Brex Card",
        account_kind: "card",
        status: card_accounts.map { |account| account.with_indifferent_access[:status] }.compact.first,
        card_accounts_count: card_accounts.count,
        current_balance: totals[:current_balance],
        available_balance: totals[:available_balance],
        account_limit: totals[:account_limit],
        raw_card_accounts: BrexAccount.sanitize_payload(card_accounts)
      }.compact
    end

    def sum_money(money_values)
      normalized = money_values.compact
      return nil if normalized.empty?

      currencies = normalized.map { |money| BrexAccount.currency_code_from_money(money) }.uniq
      if currencies.many?
        Rails.logger.warn "Brex API: Cannot aggregate card balances with mixed currencies: #{currencies.join(', ')}"
        return nil
      end

      currency = currencies.first
      total = normalized.sum do |money|
        money.with_indifferent_access[:amount].to_i
      end

      { amount: total, currency: currency }
    end

    def posted_at_start_params(start_date)
      return {} if start_date.blank?

      { posted_at_start: rfc3339_start_date(start_date) }
    end

    def get_paginated(path, params: {})
      records = []
      cursor = nil
      seen_cursors = Set.new
      page_count = 0

      loop do
        page_count += 1
        raise BrexError.new("Brex pagination exceeded #{MAX_PAGES} pages", :pagination_error) if page_count > MAX_PAGES

        page_params = params.compact.merge(limit: DEFAULT_LIMIT)
        page_params[:cursor] = cursor if cursor.present?

        response_payload = get_json(path, params: page_params)
        if response_payload.is_a?(Array)
          records.concat(response_payload)
          break
        end

        page_records = extract_records(response_payload)
        records.concat(page_records)

        next_cursor = response_payload.with_indifferent_access[:next_cursor]
        break if next_cursor.blank?

        if seen_cursors.include?(next_cursor)
          raise BrexError.new("Brex pagination returned a repeated cursor", :pagination_error)
        end

        seen_cursors.add(next_cursor)
        cursor = next_cursor
      end

      records
    end

    def get_json(path, params: {})
      query = params.present? ? "?#{URI.encode_www_form(params)}" : ""
      request_path = "#{path}#{query}"

      response = self.class.get(
        "#{base_url}#{request_path}",
        headers: auth_headers
      )

      handle_response(response, path: path)
    rescue BrexError
      raise
    rescue SocketError, Net::OpenTimeout, Net::ReadTimeout => e
      Rails.logger.error "Brex API: GET #{path} failed: #{e.class}: #{e.message}"
      raise BrexError.new("Exception during GET request: #{e.message}", :request_failed)
    rescue JSON::ParserError => e
      Rails.logger.error "Brex API: invalid JSON for GET #{path}: #{e.message}"
      raise BrexError.new("Invalid response from Brex API", :invalid_response)
    rescue => e
      Rails.logger.error "Brex API: Unexpected error during GET #{path}: #{e.class}: #{e.message}"
      raise BrexError.new("Exception during GET request: #{e.message}", :request_failed)
    end

    def extract_records(response_payload)
      return response_payload if response_payload.is_a?(Array)

      payload = response_payload.with_indifferent_access
      payload[:items] ||
        payload[:data] ||
        payload[:accounts] ||
        payload[:transactions] ||
        []
    end

    def auth_headers
      {
        "Authorization" => "Bearer #{token}",
        "Content-Type" => "application/json",
        "Accept" => "application/json"
      }
    end

    def handle_response(response, path:)
      trace_id = brex_trace_id(response)

      case response.code
      when 200
        parse_json(response.body)
      when 400
        Rails.logger.error "Brex API: bad request for #{path} trace_id=#{trace_id}"
        raise BrexError.new("Bad request to Brex API", :bad_request, http_status: 400, trace_id: trace_id)
      when 401
        Rails.logger.warn "Brex API: unauthorized for #{path} trace_id=#{trace_id}"
        raise BrexError.new("Invalid Brex API token or account permissions", :unauthorized, http_status: 401, trace_id: trace_id)
      when 403
        Rails.logger.warn "Brex API: access forbidden for #{path} trace_id=#{trace_id}"
        raise BrexError.new("Access forbidden - check Brex API token scopes", :access_forbidden, http_status: 403, trace_id: trace_id)
      when 404
        Rails.logger.warn "Brex API: resource not found for #{path} trace_id=#{trace_id}"
        raise BrexError.new("Brex resource not found", :not_found, http_status: 404, trace_id: trace_id)
      when 429
        Rails.logger.warn "Brex API: rate limited for #{path} trace_id=#{trace_id}"
        raise BrexError.new("Brex rate limit exceeded. Please try again later.", :rate_limited, http_status: 429, trace_id: trace_id)
      else
        Rails.logger.error "Brex API: unexpected response code=#{response.code} path=#{path} trace_id=#{trace_id}"
        raise BrexError.new("Failed to fetch data from Brex API: HTTP #{response.code}", :fetch_failed, http_status: response.code, trace_id: trace_id)
      end
    end

    def parse_json(body)
      return {} if body.blank?

      JSON.parse(body, symbolize_names: true)
    end

    def rfc3339_start_date(start_date)
      time =
        case start_date
        when Time
          start_date
        when DateTime
          start_date.to_time
        when Date
          start_date.to_time(:utc)
        else
          Time.zone.parse(start_date.to_s)
        end

      raise ArgumentError, "Invalid start_date: #{start_date.inspect}" if time.nil?

      time.utc.iso8601
    end

    def brex_trace_id(response)
      headers = response.respond_to?(:headers) ? response.headers : {}
      headers["X-Brex-Trace-Id"].presence ||
        headers["x-brex-trace-id"].presence
    end

    class BrexError < StandardError
      attr_reader :error_type, :http_status, :trace_id

      def initialize(message, error_type = :unknown, http_status: nil, trace_id: nil)
        super(message)
        @error_type = error_type
        @http_status = http_status
        @trace_id = trace_id
      end
    end
end
