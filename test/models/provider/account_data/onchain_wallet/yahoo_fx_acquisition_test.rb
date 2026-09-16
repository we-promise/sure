require "test_helper"

class Provider::AccountData::OnchainWallet::YahooFxAcquisitionTest < ActiveSupport::TestCase
  Wallet = Provider::AccountData::OnchainWallet
  Reader = Wallet::YahooFxReader

  setup do
    @date = Date.new(2026, 9, 15)
    @at = Time.utc(2026, 9, 15, 12)
    @options = { "version" => 1, "provider" => "yahoo_finance", "endpoint" => "https://fx.example.test",
      "user_agent" => "captured-agent/v1", "min_interval_seconds" => "0.5", "acquisition_policy" => Wallet::FxAcquisition.yahoo_policy }
    @configuration = Reader.new(options: @options).configuration
    @steps = []
    Reader::Http.expects(:get).never
  end

  test "direct history has separately referenced cookie crumb and chart without secret descriptors" do
    result = acquire(%w[response response response])
    assert_equal "0.9", result.fetch("rate")
    assert_equal "2026-09-14", result.fetch("date")
    assert_equal %w[cookie crumb chart], @steps.map { |step| step.dig(:arguments, :step) }
    assert_equal({ "cookie" => reference_at(0) }, @steps[1].dig(:arguments, :auth_refs))
    assert_equal({ "cookie" => reference_at(0), "crumb" => reference_at(1) }, @steps[2].dig(:arguments, :auth_refs))
    refute_includes JSON.generate(@steps.map { |step| step.fetch(:arguments) }), "private-"
    refute_includes JSON.generate(result), "private-"
  end

  test "only an explicit unavailable direct pair permits inverse using the same captured session" do
    result = acquire(%w[response response pair_unavailable response])
    assert_equal "inverse", result.fetch("direction")
    assert_equal "0.333333333333", result.fetch("rate")
    assert_equal %w[cookie crumb chart chart], @steps.map { |step| step.dig(:arguments, :step) }
    assert_equal @steps[2].dig(:arguments, :auth_refs), @steps[3].dig(:arguments, :auth_refs)
    assert_equal [ "direct", "inverse" ], @steps.last(2).map { |step| step.dig(:arguments, :direction) }
  end

  test "valid empty malformed and terminal direct results do not silently try inverse" do
    %w[empty invalid_response request_failed forbidden].each do |status|
      @steps = []
      assert_nil acquire([ "response", "response", status ])
      assert_equal 3, @steps.size
      assert_equal "direct", @steps.last.dig(:arguments, :direction)
    end
  end

  test "one embedded Unauthorized refresh per direction bounds the full branch to ten steps" do
    result = acquire(%w[response response authentication_failed response response pair_unavailable authentication_failed response response response])
    assert_equal "inverse", result.fetch("direction")
    assert_equal 10, @steps.size
    assert_equal [ 0, 0, 0, 1, 1, 1, 1, 2, 2, 2 ], @steps.map { |step| step.dig(:arguments, :auth_generation) }
    assert_equal [ "cookie", "crumb", "chart", "cookie", "crumb", "chart", "chart", "cookie", "crumb", "chart" ], @steps.map { |step| step.dig(:arguments, :step) }
  end

  test "a second authentication failure in one direction terminates without another cookie or inverse" do
    assert_nil acquire(%w[response response authentication_failed response response authentication_failed])
    assert_equal 6, @steps.size
    assert_equal [ 0, 1 ], @steps.select { |step| step.dig(:arguments, :step) == "cookie" }.map { |step| step.dig(:arguments, :auth_generation) }
  end

  test "captured local cookie crumb and chart expiry each consumes a bounded refresh" do
    [ %w[auth_expired response response response], %w[response auth_expired response response response],
      %w[response response auth_expired response response response] ].each do |statuses|
      @steps = []
      assert acquire(statuses)
      assert_equal 1, @steps.last.dig(:arguments, :auth_generation)
      assert_equal "2026-09-15", @steps.last.dig(:arguments, :date)
    end
    @steps = []
    assert_nil acquire(%w[auth_expired auth_expired])
    assert_equal 2, @steps.size
  end

  test "replay uses captured expiry and request clocks independently of the current wall clock" do
    result = acquire(%w[response response auth_expired response response response])
    read = lambda do |action, **arguments|
      @steps.find { |step| step[:action] == action && step[:arguments] == arguments }&.fetch(:capture) || flunk("Replay changed operation")
    end
    travel_to(@at + 10.days) do
      assert_equal result, Wallet::FxAcquisition.new(options: @options, from: "USD", to: "EUR", date: @date, read: read, reference: method(:reference)).call
    end
  end

  test "changed endpoint header policy or response identity cannot be recaptured as the new baseline" do
    acquire(%w[response response response])
    first = @steps.first.fetch(:capture)
    [ { "endpoint" => "https://different.example.test" }, { "user_agent" => "other-agent" } ].each do |change|
      assert_raises(Provider::AccountData::InvalidResponse) do
        Wallet::FxAcquisition.new(options: @options.merge(change), from: "USD", to: "EUR", date: @date,
          read: ->(_action, **_arguments) { first }, reference: method(:reference)).call
      end
    end
    assert_raises(ArgumentError) do
      Wallet::FxAcquisition.new(options: @options.merge("acquisition_policy" => {}), from: "USD", to: "EUR", date: @date,
        read: ->(*) { flunk "Unreviewed policy read data" }, reference: method(:reference)).call
    end
  end

  private
    def acquire(statuses)
      choices = statuses.dup
      read = lambda do |action, **arguments|
        status = choices.shift || flunk("Acquisition exceeded expected steps")
        capture = envelope(arguments, status)
        @steps << { action: action, arguments: arguments, capture: capture }
        capture
      end
      result = Wallet::FxAcquisition.new(options: @options, from: "USD", to: "EUR", date: @date, read: read, reference: method(:reference)).call
      assert_empty choices
      result
    end

    def reference(action, **arguments)
      index = @steps.index { |step| step[:action] == action && step[:arguments] == arguments } || raise(ArgumentError)
      reference_at(index)
    end

    def reference_at(index)
      { "index" => index, "sha256" => Wallet::CaptureArchive.digest(@steps.fetch(index)) }
    end

    def envelope(arguments, status)
      step = arguments.fetch(:step)
      generation = arguments.fetch(:auth_generation)
      direction = arguments[:direction]
      request = Reader.request(action: step, from: "USD", to: "EUR", date: @date, auth_generation: generation, direction: direction)
      response = if status == "response" || status == "empty"
        case step
        when "cookie" then { "cookie" => "A3=private-cookie-#{generation}", "expires_at" => (@at + 3600).iso8601(9) }
        when "crumb"
          cookie = @steps.fetch(arguments.fetch(:auth_refs).fetch("cookie").fetch("index")).fetch(:capture)
          { "crumb" => "private-crumb-#{generation}", "cookie_digest" => Reader.digest(cookie), "expires_at" => cookie.dig("response", "expires_at") }
        when "chart"
          { "symbol" => direction == "inverse" ? "EURUSD=X" : "USDEUR=X",
            "observations" => status == "empty" ? [] : [ { "timestamp" => Time.utc(2026, 9, 14).to_i, "close" => direction == "inverse" ? "3" : "0.9" } ] }
        end
      else
        {}
      end
      code = status == "auth_expired" ? nil : (status == "forbidden" ? 403 : 200)
      status = "response" if status == "empty"
      status = "authentication_failed" if status == "forbidden"
      { "version" => 1, "policy" => Reader::POLICY, "provider" => Reader::PROVIDER, "configuration" => @configuration,
        "action" => step, "request" => request, "requested_at" => @at.iso8601(9), "status" => status, "http_status" => code, "response" => response }
    end
end
