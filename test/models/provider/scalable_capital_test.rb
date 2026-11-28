require "test_helper"

class Provider::ScalableCapitalTest < ActiveSupport::TestCase
  class TestClient < Provider::ScalableCapital
    attr_reader :requests

    def initialize(responses)
      super(executable: "/usr/local/bin/sc")
      @responses = responses
      @requests = []
    end

    private

      def capture(args)
        @requests << args
        @responses.shift
      end

      def sleep(_duration)
      end
  end

  test "reads only the expected Scalable CLI commands with explicit account IDs" do
    client = TestClient.new(Array.new(7) { success("result" => { "items" => [], "cursor" => nil }) })
    since = Time.iso8601("2026-11-20T00:00:00+01:00")
    before = since + 1.day
    client.overview("portfolio")
    client.cash("portfolio")
    client.holdings("portfolio")
    client.trade("portfolio", "trade-id")
    client.overnight("savings")
    client.broker_transactions("portfolio", since: since, before: before) { |_, rows| assert_empty rows }
    client.overnight_transactions("savings", since: since, before: before) { |_, rows| assert_empty rows }

    assert_equal [
      %w[broker overview --portfolio-id portfolio],
      %w[broker cash-breakdown --portfolio-id portfolio],
      %w[broker holdings --portfolio-id portfolio],
      %w[broker transaction details --portfolio-id portfolio --transaction-id=trade-id],
      %w[overnight --savings-account-id savings],
      %w[broker transactions --portfolio-id portfolio --from-time 2026-11-20T00:00:00+01:00 --to-time 2026-11-21T00:00:00+01:00 --page-size 100],
      %w[overnight transactions --savings-account-id savings --from-time 2026-11-20T00:00:00+01:00 --to-time 2026-11-21T00:00:00+01:00 --page-size 100]
    ], client.requests
  end

  test "follows the cursor and rejects a repeated one" do
    page = { "result" => { "items" => [ { "id" => "id" } ], "cursor" => "next" } }
    client = TestClient.new([ success(page), success(page) ])

    assert_raises Provider::ScalableCapital::InvalidResponse do
      client.broker_transactions("portfolio", since: 1.day.ago, before: Time.current) { |_, rows| assert_equal [ { "id" => "id" } ], rows }
    end
    assert_equal "--cursor=next", client.requests.last.last
  end

  test "an expired session returns a reconnect message with no CLI output" do
    failure = { ok: false, error: { code: "refresh_relogin_required", message: "untrusted stderr contents" } }
    client = TestClient.new([ [ failure.to_json, stub(success?: false) ] ])

    error = assert_raises(Provider::ScalableCapital::AuthenticationError) { client.overview("portfolio") }
    assert_match(/sign in again/i, error.message)
    refute_includes error.message, "untrusted"
  end

  test "reads identity and broker choices without changing CLI context" do
    client = TestClient.new([
      success("result" => { "personOverview" => { "id" => "person" } }, "session" => { "local_read_only" => true }),
      success("portfolios" => [ { "portfolio_id" => "portfolio" }, { "portfolio_id" => "portfolio" } ])
    ])

    assert_equal "person", client.identity
    assert_equal [ "portfolio" ], client.portfolios
    assert_equal [ %w[whoami], %w[broker portfolios] ], client.requests
  end

  test "reads only market data commands for security search, quotes and candlesticks" do
    client = TestClient.new(Array.new(3) { success({}) })
    client.search_securities("portfolio", "Example ETF")
    client.security_quote("portfolio", "IE00B4L5Y983")
    client.security_candlesticks("IE00B4L5Y983", "one_month")

    assert_raises(Provider::ScalableCapital::InvalidResponse) { client.search_securities("portfolio", "--confirm") }
    assert_equal [
      [ "broker", "search", "--portfolio-id", "portfolio", "Example ETF" ],
      %w[broker quote --portfolio-id portfolio --isin=IE00B4L5Y983],
      %w[broker candlesticks --isin=IE00B4L5Y983 --timeframe=one_month]
    ], client.requests
  end

  test "rejects a session without the local read-only mode" do
    client = TestClient.new([ success("session" => { "local_read_only" => false }) ])

    assert_raises(Provider::ScalableCapital::AuthenticationError) { client.identity }
  end

  test "verifies personal and junior overnight choices by their explicit IDs" do
    message = "Unable to resolve overnight savings account id: multiple active overnight accounts found [adult (Tagesgeld, personal), child (Junior Savings, junior)]. Provide --savings-account-id <ID>."
    failure = { ok: false, error: { code: "overnight_selection_required", message: message } }
    client = TestClient.new([
      [ failure.to_json, stub(success?: false) ],
      success("savings_account_id" => "adult"),
      success("savings_account_id" => "child")
    ])

    assert_equal %w[adult child], client.overnight_accounts.pluck("savings_account_id")
    assert_equal [ %w[overnight], %w[overnight --savings-account-id adult], %w[overnight --savings-account-id child] ], client.requests
  end

  test "does not present a truncated savings account list as complete" do
    failure = { ok: false, error: { code: "overnight_selection_required", message: "Unable to resolve overnight savings account id: multiple active overnight accounts found [adult (Tagesgeld, personal), ..." } }
    client = TestClient.new([ [ failure.to_json, stub(success?: false) ] ])

    assert_raises(Provider::ScalableCapital::OvernightDiscoveryUnavailable) { client.overnight_accounts }
    assert_equal [ %w[overnight] ], client.requests
  end

  private

    def success(data)
      [ { ok: true, data: data }.to_json, stub(success?: true) ]
    end
end
