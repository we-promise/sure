# frozen_string_literal: true

require "test_helper"

class Api::V1::ExchangeRatesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)

    # Destroy existing active API keys to avoid validation errors
    @user.api_keys.active.destroy_all

    @api_key = ApiKey.create!(
      user: @user,
      name: "Test Read-Write Key",
      scopes: [ "read_write" ],
      display_key: "test_rw_#{SecureRandom.hex(8)}"
    )

    @read_only_api_key = ApiKey.create!(
      user: @user,
      name: "Test Read-Only Key",
      scopes: [ "read" ],
      display_key: "test_ro_#{SecureRandom.hex(8)}",
      source: "mobile"
    )

    # Clear any existing rate limit data
    Redis.new.del("api_rate_limit:#{@api_key.id}")
    Redis.new.del("api_rate_limit:#{@read_only_api_key.id}")

    ExchangeRate.delete_all
    @rate = ExchangeRate.create!(from_currency: "EUR", to_currency: "USD", date: Date.new(2026, 6, 1), rate: 1.08)

    # Rate writes are self-hosted-only; most tests exercise that mode.
    Rails.configuration.stubs(:app_mode).returns("self_hosted".inquiry)
  end

  test "index returns exchange rates with pagination" do
    ExchangeRate.create!(from_currency: "GBP", to_currency: "USD", date: Date.new(2026, 6, 1), rate: 1.27)

    get api_v1_exchange_rates_url, headers: api_headers(@api_key)

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal 2, body["exchange_rates"].size
    assert body.key?("pagination")
    assert_equal 2, body["pagination"]["total_count"]
  end

  test "index filters by currency pair and date range" do
    ExchangeRate.create!(from_currency: "GBP", to_currency: "USD", date: Date.new(2026, 6, 1), rate: 1.27)
    ExchangeRate.create!(from_currency: "EUR", to_currency: "USD", date: Date.new(2026, 5, 1), rate: 1.07)

    get api_v1_exchange_rates_url(from: "eur", to: "USD", start_date: "2026-05-15"), headers: api_headers(@api_key)

    assert_response :success
    rates = JSON.parse(response.body)["exchange_rates"]
    assert_equal 1, rates.size
    assert_equal "EUR", rates.first["from_currency"]
    assert_equal "2026-06-01", rates.first["date"]
  end

  test "index rejects an unknown currency filter" do
    get api_v1_exchange_rates_url(from: "NOPE"), headers: api_headers(@api_key)

    assert_response :unprocessable_entity
    assert_equal "validation_failed", JSON.parse(response.body)["error"]
  end

  test "index requires an API key" do
    get api_v1_exchange_rates_url

    assert_response :unauthorized
  end

  test "show returns a single exchange rate" do
    get api_v1_exchange_rate_url(@rate), headers: api_headers(@api_key)

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal @rate.id, body["id"]
    assert_equal "EUR", body["from_currency"]
    assert_equal "USD", body["to_currency"]
  end

  test "show returns 404 for unknown or malformed ids" do
    get api_v1_exchange_rate_url("not-a-uuid"), headers: api_headers(@api_key)
    assert_response :not_found

    get api_v1_exchange_rate_url(SecureRandom.uuid), headers: api_headers(@api_key)
    assert_response :not_found
  end

  test "create inserts a new exchange rate" do
    assert_difference "ExchangeRate.count", 1 do
      post api_v1_exchange_rates_url,
        params: { from: "chf", to: "usd", date: "2026-06-15", rate: "1.12" },
        headers: api_headers(@api_key)
    end

    assert_response :created
    body = JSON.parse(response.body)
    assert_equal "CHF", body["from_currency"]
    assert_equal "USD", body["to_currency"]
    assert_equal "2026-06-15", body["date"]
    assert_equal "1.12", body["rate"].to_s.sub(/0+\z/, "")
  end

  test "create upserts idempotently on from, to and date" do
    assert_no_difference "ExchangeRate.count" do
      post api_v1_exchange_rates_url,
        params: { from: "EUR", to: "USD", date: "2026-06-01", rate: "1.10" },
        headers: api_headers(@api_key)
    end

    assert_response :ok
    assert_equal 1.10.to_d, @rate.reload.rate
  end

  test "create retries as an update when a concurrent request wins the uniqueness race" do
    # Simulates two concurrent POSTs for the same (from, to, date): both pass
    # find_or_initialize_by before either has saved, so ours must lose the
    # validation-level uniqueness check (RecordInvalid), not just the DB
    # index (RecordNotUnique), and retry as an update against the winner.
    winner = ExchangeRate.create!(from_currency: "JPY", to_currency: "USD", date: Date.new(2026, 6, 20), rate: 150.0)

    racing_record = ExchangeRate.new(from_currency: "JPY", to_currency: "USD", date: Date.new(2026, 6, 20))
    racing_record.define_singleton_method(:update!) do |*|
      raise ActiveRecord::RecordInvalid, self
    end
    ExchangeRate.stubs(:find_or_initialize_by).returns(racing_record)

    assert_no_difference "ExchangeRate.count" do
      post api_v1_exchange_rates_url,
        params: { from: "JPY", to: "USD", date: "2026-06-20", rate: "151.0" },
        headers: api_headers(@api_key)
    end

    assert_response :ok
    assert_equal 151.0.to_d, winner.reload.rate
  end

  test "create rejects invalid payloads" do
    post api_v1_exchange_rates_url,
      params: { from: "EUR", to: "USD", date: "junk", rate: "1.1" },
      headers: api_headers(@api_key)
    assert_response :unprocessable_entity

    post api_v1_exchange_rates_url,
      params: { from: "EUR", to: "USD", date: "2026-06-15", rate: "-2" },
      headers: api_headers(@api_key)
    assert_response :unprocessable_entity

    post api_v1_exchange_rates_url,
      params: { from: "EUR", to: "EUR", date: "2026-06-15", rate: "1" },
      headers: api_headers(@api_key)
    assert_response :unprocessable_entity

    post api_v1_exchange_rates_url,
      params: { from: "EUR", to: "USD", rate: "1.1" },
      headers: api_headers(@api_key)
    assert_response :bad_request
  end

  test "create requires write scope" do
    assert_no_difference "ExchangeRate.count" do
      post api_v1_exchange_rates_url,
        params: { from: "EUR", to: "USD", date: "2026-06-15", rate: "1.1" },
        headers: api_headers(@read_only_api_key)
    end

    assert_response :forbidden
  end

  test "create is rejected on managed hosting" do
    Rails.configuration.stubs(:app_mode).returns("managed".inquiry)

    assert_no_difference "ExchangeRate.count" do
      post api_v1_exchange_rates_url,
        params: { from: "EUR", to: "USD", date: "2026-06-15", rate: "1.1" },
        headers: api_headers(@api_key)
    end

    assert_response :forbidden
    assert_equal "forbidden", JSON.parse(response.body)["error"]
  end

  private

    def api_headers(api_key)
      { "X-Api-Key" => api_key.plain_key }
    end
end
