# frozen_string_literal: true

require "digest"
require "cgi"

# Pluggy (pluggy.ai) API client — a banking/investment aggregator.
#
# Auth model: POST /auth { clientId, clientSecret } -> { apiKey } (2h TTL,
# Pluggy returns no expiresIn), then every authenticated request sends an
# `X-API-KEY: <apiKey>` header (NOT a Bearer token). The cached apiKey is
# shared across calls for the same credential fingerprint and refreshed once
# on a 401 via `send_with_auth`.
#
# This is the SDK foundation (Task 2). Endpoint methods (connect_token,
# accounts, transactions, investments) are added in later tasks and should
# route through `send_with_auth` so they inherit the 401 retry.
class Provider::Pluggy
  include HTTParty
  extend SslConfigurable

  DEFAULT_BASE_URL = "https://api.pluggy.ai"
  API_KEY_TTL = 7_200 # 2 hours; Pluggy /auth returns no expiresIn
  PAGE_SIZE = 500

  default_options.merge!({ timeout: 120 }.merge(httparty_ssl_options))

  class Error < StandardError
    attr_reader :error_type

    def initialize(message, error_type = :unknown)
      super(message)
      @error_type = error_type
    end
  end
  class ConfigurationError < Error; end
  class AuthenticationError < Error; end

  # Guards the /auth call so concurrent first-time callers don't each re-auth.
  @api_key_mutex = Mutex.new

  class << self
    def base_url
      Rails.configuration.x.pluggy&.base_url || DEFAULT_BASE_URL
    end

    # Pluggy authenticates with an `X-API-KEY` header (not Bearer).
    def auth_headers(api_key:)
      headers = { "Content-Type" => "application/json", "User-Agent" => "Sure Finance Pluggy Client" }
      headers["X-API-KEY"] = api_key if api_key
      headers
    end

    # Returns a cached apiKey for the credential pair. `force:` bypasses the
    # cache so a known-stale key (after a 401) can be refreshed. Mutex-guarded
    # with a double-check so concurrent callers share one /auth round-trip.
    def api_key(client_id:, client_secret:, force: false)
      cache_key = "pluggy_api_key/#{cache_fingerprint(client_id, client_secret)}"
      existing = Rails.cache.read(cache_key)
      return existing if existing && !force

      @api_key_mutex.synchronize do
        return Rails.cache.read(cache_key) if Rails.cache.exist?(cache_key) && !force
        response = post(
          "#{base_url}/auth",
          body: { clientId: client_id, clientSecret: client_secret }.to_json,
          headers: auth_headers(api_key: nil)
        )
        handle_response(response)
        key = parsed(response)[:apiKey] || parsed(response)["apiKey"]
        raise AuthenticationError.new("Pluggy auth returned no apiKey", :unauthorized) if key.blank?
        Rails.cache.write(cache_key, key, expires_in: API_KEY_TTL)
        key
      end
    end

    # Single seam for authenticated requests; refreshes the cached key once on 401.
    def send_with_auth(method, path, client_id:, client_secret:, query: nil, body: nil)
      perform(method, path, client_id:, client_secret:, force: false, query:, body:)
    rescue AuthenticationError => e
      raise e unless e.error_type == :unauthorized
      perform(method, path, client_id:, client_secret:, force: true, query:, body:)
    end

    def perform(method, path, client_id:, client_secret:, force:, query:, body:)
      key = api_key(client_id:, client_secret:, force:)
      opts = { headers: auth_headers(api_key: key) }
      opts[:query] = query if query
      opts[:body] = body if body
      uri = path.start_with?("http") ? path : "#{base_url}#{path}"
      resp = method == :get ? get(uri, opts) : send(method, uri, opts)
      handle_response(resp)
      parsed(resp)
    end

    def handle_response(resp)
      case resp.code
      when 200, 201 then parsed(resp)
      when 400 then raise Error.new("Bad request: #{resp.body}", :bad_request)
      when 401 then raise AuthenticationError.new("Invalid credentials", :unauthorized)
      when 403 then raise AuthenticationError.new("Access forbidden", :access_forbidden)
      when 404 then raise Error.new("Not found: #{resp.body}", :not_found)
      when 429 then raise Error.new("Rate limited", :rate_limited)
      else raise Error.new("Pluggy request failed (#{resp.code}): #{resp.body}", :fetch_failed)
      end
    end

    def parsed(resp)
      body = resp.parsed_response
      return {} if body.blank?
      body.is_a?(Hash) ? body.with_indifferent_access : JSON.parse(body.to_s).with_indifferent_access
    rescue JSON::ParserError, TypeError
      {}
    end

    # Task 3: connect_token + item lifecycle. All route through `send_with_auth`
    # so they inherit the cached-key + 401 retry seam.
    #
    # `avoid_duplicates` default is `nil` (NOT `true`) so the SDK can derive the
    # flag from `item_id` presence and callers stay agnostic. This fixes
    # ITEM_USER_ALREADY_EXISTS after a Docker `-v` wipe that orphans the
    # Pluggy-side item (the wipe clears Sure's `pluggy_items` row but the
    # upstream bank-credential item survives). With `avoidDuplicates: true` in
    # CREATE mode (blank `item_id`), Pluggy's dup-check on the *institution bank
    # credentials* the user types into the widget matches the orphan and 400s.
    # Deriving `false` in CREATE mode lets the widget RE-BIND the surviving
    # upstream item instead of 400-ing; deriving `true` in UPDATE mode (item_id
    # present) preserves the re-auth dedup safety net. An explicit
    # `avoid_duplicates:` override still wins.
    def connect_token(client_id:, client_secret:, client_user_id:, webhook_url:, redirect_url:, avoid_duplicates: nil, item_id: nil)
      effective_avd = avoid_duplicates.nil? ? item_id.present? : avoid_duplicates
      body = {
        options: {
          clientUserId: client_user_id,
          oauthRedirectUri: redirect_url,
          avoidDuplicates: effective_avd
        }
      }
      body[:options][:webhookUrl] = webhook_url if webhook_url.present?
      body[:itemId] = item_id if item_id
      data = send_with_auth(:post, "/connect_token", client_id:, client_secret:, body: body.to_json)
      token = data[:accessToken] || data["accessToken"]
      raise Error.new("Pluggy connect_token returned no accessToken", :fetch_failed) if token.blank?
      token
    end

    def get_item(item_id:, client_id:, client_secret:)
      send_with_auth(:get, "/items/#{item_id}", client_id:, client_secret:)
    end

    def list_items(client_id:, client_secret:, client_user_id: nil)
      results = []
      page = 1
      total_pages = 1

      while page <= total_pages
        query = { page: page, pageSize: PAGE_SIZE }
        query[:clientUserId] = client_user_id if client_user_id.present?

        data = send_with_auth(:get, "/items", client_id:, client_secret:, query:)
        total_pages = (data[:totalPages] || data["totalPages"] || 1).to_i
        results += (data[:results] || data["results"] || [])
        page += 1
      end

      results
    end

    def latest_item_id(client_id:, client_secret:, client_user_id: nil)
      # First try with the specific clientUserId (for family-scoped items)
      items = list_items(client_id:, client_secret:, client_user_id:)
      if items.blank? && client_user_id.present?
        # Fallback: if no items found with clientUserId filter, try without it
        # This handles demo items or items created outside the family context
        items = list_items(client_id:, client_secret:, client_user_id: nil)
      end
      return nil if items.blank?

      latest = items.max_by do |item|
        ts = item[:updatedAt] || item["updatedAt"] || item[:createdAt] || item["createdAt"]
        Time.zone.parse(ts.to_s)&.to_i || 0
      rescue StandardError
        0
      end

      latest&.dig(:id) || latest&.dig("id")
    end

    def update_item(item_id:, client_user_id:, credentials:, client_id:, client_secret:)
      body = { clientUserId: client_user_id, credentials: credentials }
      send_with_auth(:put, "/items/#{item_id}", client_id:, client_secret:, body: body.to_json)
    end

    def delete_item(item_id:, client_id:, client_secret:)
      send_with_auth(:delete, "/items/#{item_id}", client_id:, client_secret:)
      true
    end

    # Task 4: accounts (page-based loop until totalPages).
    def get_accounts(item_id:, client_id:, client_secret:, type: nil)
      results = []
      page = 1
      total_pages = 1
      while page <= total_pages
        query = { itemId: item_id, page: page, pageSize: PAGE_SIZE }
        query[:type] = type if type
        data = send_with_auth(:get, "/accounts", client_id:, client_secret:, query:)
        total_pages = (data[:totalPages] || data["totalPages"] || 1).to_i
        results += (data[:results] || data["results"] || [])
        page += 1
      end
      results
    end

    # Task 5: transactions (cursor-based loop following `next` until null).
    def get_account_transactions(account_id:, client_id:, client_secret:, date_from: nil, date_to: nil)
      results = []
      after = nil
      loop do
        page = page_transactions(account_id:, after:, client_id:, client_secret:, date_from:, date_to:)
        results += (page[:results] || page["results"] || [])
        after = normalize_transactions_cursor(page[:next] || page["next"])
        break if after.blank?
      end
      results
    end

    def page_transactions(account_id:, after:, client_id:, client_secret:, date_from:, date_to:)
      query = { accountId: account_id }
      query[:after] = after if after
      query[:dateFrom] = date_from.iso8601 if date_from
      query[:dateTo] = date_to.iso8601 if date_to
      send_with_auth(:get, "/v2/transactions", client_id:, client_secret:, query:)
    end

    # Task 6: investments + investment transactions (page loop via shared paged).
    def get_investments(item_id:, client_id:, client_secret:)
      paged("/investments", query_extra: { itemId: item_id }, client_id:, client_secret:)
    end

    def get_investment_transactions(investment_id:, client_id:, client_secret:)
      paged("/investments/#{investment_id}/transactions", query_extra: {}, client_id:, client_secret:)
    end

    def paged(path, query_extra:, client_id:, client_secret:)
      results = []
      page = 1
      total_pages = 1
      while page <= total_pages
        query = query_extra.merge(page: page, pageSize: PAGE_SIZE)
        data = send_with_auth(:get, path, client_id:, client_secret:, query:)
        total_pages = (data[:totalPages] || data["totalPages"] || 1).to_i
        results += (data[:results] || data["results"] || [])
        page += 1
      end
      results
    end

    private

      # Pluggy may return `next` either as a raw cursor token or as a query-like
      # string (e.g. "?accountId=...&after=..."). Normalize both to the token.
      def normalize_transactions_cursor(next_value)
        return nil if next_value.blank?

        str = next_value.to_s
        return str unless str.start_with?("?")

        query = CGI.parse(str.delete_prefix("?"))
        query["after"]&.first || query["cursor"]&.first
      end

      def cache_fingerprint(client_id, client_secret)
        Digest::MD5.hexdigest("#{client_id}:#{client_secret}")
      end
  end
end
