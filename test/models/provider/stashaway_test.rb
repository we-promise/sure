require "test_helper"

class Provider::StashawayTest < ActiveSupport::TestCase
  BASE = "https://api.stashaway.sg".freeze
  JSON_HEADERS = { "Content-Type" => "application/json" }.freeze

  setup do
    @provider = Provider::Stashaway.new(region: "sg", token: "api-token")
    Provider::Stashaway.any_instance.stubs(:sleep)
  end

  test "signs in with the web app's client id and the device id" do
    request = stub_request(:post, "#{BASE}/api/v2/auth/login")
      .with(
        headers: { "x-client-identifier" => "webapp@4.4.0" },
        body: { email: "investor@example.com", password: "secret", userData: { deviceCookie: "device-1" } }.to_json
      )
      .to_return(status: 200, body: { token: "login-token", userId: "user-1", customerProgress: { state: "DONE" } }.to_json, headers: JSON_HEADERS)

    session = Provider::Stashaway.new(region: "sg").login(email: "investor@example.com", password: "secret", device_id: "device-1")

    assert_equal "login-token", session.token
    assert_equal "user-1", session.user_id
    assert_not session.two_factor_required
    assert_requested request
    assert_not_requested :post, "#{BASE}/api/v2/auth/login", headers: { "Authorization" => /Bearer/ }
  end

  test "a refused password is invalid credentials with StashAway's reason" do
    stub_request(:post, "#{BASE}/api/v2/auth/login")
      .to_return(status: 401, body: { message: "Incorrect email or password" }.to_json, headers: JSON_HEADERS)

    error = assert_raises(Provider::Stashaway::InvalidCredentials) do
      Provider::Stashaway.new(region: "sg").login(email: "investor@example.com", password: "wrong", device_id: "device-1")
    end

    assert_equal "Incorrect email or password", error.message
  end

  test "a 401 asking for 2FA returns the token for the SMS code steps" do
    stub_request(:post, "#{BASE}/api/v2/auth/login")
      .to_return(status: 401, body: { message: "2FA", token: "pre-2fa-token", userId: "user-1" }.to_json, headers: JSON_HEADERS)

    session = Provider::Stashaway.new(region: "sg").login(email: "investor@example.com", password: "secret", device_id: "device-1")

    assert session.two_factor_required
    assert_equal "pre-2fa-token", session.token
    assert_equal "user-1", session.user_id
  end

  test "a 401 asking for 2FA without a token is an error" do
    stub_request(:post, "#{BASE}/api/v2/auth/login")
      .to_return(status: 401, body: { message: "2FA" }.to_json, headers: JSON_HEADERS)

    assert_raises(Provider::Stashaway::ApiError) do
      Provider::Stashaway.new(region: "sg").login(email: "investor@example.com", password: "secret", device_id: "device-1")
    end
  end

  test "StashAway's newer verification flow is reported as unsupported" do
    stub_request(:post, "#{BASE}/api/v2/auth/login")
      .to_return(status: 401, body: { message: "CONOTP", token: "t", secondFactor: { otpRequired: true } }.to_json, headers: JSON_HEADERS)

    assert_raises(Provider::Stashaway::UnsupportedVerification) do
      Provider::Stashaway.new(region: "sg").login(email: "investor@example.com", password: "secret", device_id: "device-1")
    end
  end

  test "a login answer without a token is an error" do
    stub_request(:post, "#{BASE}/api/v2/auth/login").to_return(status: 200, body: { userId: "user-1" }.to_json, headers: JSON_HEADERS)

    assert_raises(Provider::Stashaway::ApiError) do
      Provider::Stashaway.new(region: "sg").login(email: "investor@example.com", password: "secret", device_id: "device-1")
    end
  end

  test "sends the SMS code for the login token and verifies it with the same device id" do
    send_request = stub_request(:post, "#{BASE}/api/v1/auth/2fa/send")
      .with(body: { token: "login-token" }.to_json)
      .to_return(status: 200, body: {}.to_json, headers: JSON_HEADERS)
    verify_request = stub_request(:post, "#{BASE}/api/v1/auth/2fa")
      .with(body: { secret: "123456", token: "login-token", userData: { deviceCookie: "device-1" } }.to_json)
      .to_return(status: 200, body: { token: "api-token" }.to_json, headers: JSON_HEADERS)

    client = Provider::Stashaway.new(region: "sg")
    assert client.send_two_factor_code(token: "login-token")
    assert_equal "api-token", client.verify_two_factor(code: " 123456 ", token: "login-token", device_id: "device-1")
    assert_requested send_request
    assert_requested verify_request
  end

  test "a refused code is an invalid code" do
    stub_request(:post, "#{BASE}/api/v1/auth/2fa").to_return(status: 400, body: { message: "Invalid OTP" }.to_json, headers: JSON_HEADERS)

    error = assert_raises(Provider::Stashaway::InvalidCode) do
      Provider::Stashaway.new(region: "sg").verify_two_factor(code: "000000", token: "login-token", device_id: "device-1")
    end

    assert_equal "Invalid OTP", error.message
  end

  test "lists goals over GraphQL with the bearer token" do
    request = stub_request(:post, "#{BASE}/graphql/goals")
      .with(headers: { "Authorization" => "Bearer api-token", "x-client-identifier" => "webapp@4.4.0" }) { |req| JSON.parse(req.body)["query"].include?("goals(state: [ACTIVE, ARCHIVED, CLOSED])") }
      .to_return(status: 200, body: { data: { goals: [ { _id: "g1", displayName: "General " } ] } }.to_json, headers: JSON_HEADERS)

    assert_equal [ { "_id" => "g1", "displayName" => "General " } ], @provider.goals
    assert_requested request
  end

  test "walks transaction pages from 0 until the count is reached" do
    page = ->(n, items, count) { { data: { goal: { _id: "g1", transactions: { count: count, items: items } } } }.to_json }
    stub_request(:post, "#{BASE}/graphql/transactions")
      .with { |req| JSON.parse(req.body).dig("variables", "page") == 0 }
      .to_return(status: 200, body: page.call(0, Array.new(100) { |i| { id: "a#{i}" } }, 150), headers: JSON_HEADERS)
    stub_request(:post, "#{BASE}/graphql/transactions")
      .with { |req| JSON.parse(req.body)["variables"] == { "goalId" => "g1", "pageSize" => 100, "page" => 1 } }
      .to_return(status: 200, body: page.call(1, Array.new(50) { |i| { id: "b#{i}" } }, 150), headers: JSON_HEADERS)

    items = @provider.goal_transactions("g1")

    assert_equal 150, items.size
    assert_equal "b49", items.last["id"]
  end

  test "an item pushed onto the next page while walking is kept once" do
    page = ->(items, count) { { data: { goal: { _id: "g1", transactions: { count: count, items: items } } } }.to_json }
    stub_request(:post, "#{BASE}/graphql/transactions")
      .with { |req| JSON.parse(req.body).dig("variables", "page") == 0 }
      .to_return(status: 200, body: page.call(Array.new(100) { |i| { id: "a#{i}" } }, 150), headers: JSON_HEADERS)
    # A reordered item moved a99 onto the second page.
    stub_request(:post, "#{BASE}/graphql/transactions")
      .with { |req| JSON.parse(req.body).dig("variables", "page") == 1 }
      .to_return(status: 200, body: page.call([ { id: "a99" }, *Array.new(50) { |i| { id: "b#{i}" } } ], 150), headers: JSON_HEADERS)

    items = @provider.goal_transactions("g1")

    assert_equal 150, items.size
    assert_equal 1, items.count { |item| item["id"] == "a99" }
    assert_not_requested(:post, "#{BASE}/graphql/transactions") { |req| JSON.parse(req.body).dig("variables", "page") == 2 }
  end

  test "a goals answer without the list is an error, not a connection without portfolios" do
    stub_request(:post, "#{BASE}/graphql/goals").to_return(status: 200, body: { data: {} }.to_json, headers: JSON_HEADERS)

    error = assert_raises(Provider::Stashaway::ApiError) { @provider.goals }
    assert_match "without a goal list", error.message
  end

  test "a transactions answer without a list or a count is an error, not an empty list" do
    stub_request(:post, "#{BASE}/graphql/transactions")
      .with { |req| JSON.parse(req.body).dig("variables", "page") == 0 }
      .to_return({ status: 200, body: { data: { goal: nil } }.to_json, headers: JSON_HEADERS },
                 { status: 200, body: { data: { goal: { _id: "g1", transactions: { items: Array.new(100) { |i| { id: "a#{i}" } } } } } }.to_json, headers: JSON_HEADERS })

    error = assert_raises(Provider::Stashaway::ApiError) { @provider.goal_transactions("g1") }
    assert_match "without a transaction list", error.message

    error = assert_raises(Provider::Stashaway::ApiError) { @provider.goal_transactions("g1") }
    assert_match "without a transaction list", error.message
  end

  test "a list that ends short of its count is an error, not a shorter list" do
    page = ->(items, count) { { data: { goal: { _id: "g1", transactions: { count: count, items: items } } } }.to_json }
    stub_request(:post, "#{BASE}/graphql/transactions")
      .with { |req| JSON.parse(req.body).dig("variables", "page") == 0 }
      .to_return(status: 200, body: page.call(Array.new(100) { |i| { id: "a#{i}" } }, 150), headers: JSON_HEADERS)
    # An item left the list while it was read, so one of the 150 was missed.
    stub_request(:post, "#{BASE}/graphql/transactions")
      .with { |req| JSON.parse(req.body).dig("variables", "page") == 1 }
      .to_return(status: 200, body: page.call(Array.new(49) { |i| { id: "b#{i}" } }, 150), headers: JSON_HEADERS)
    stub_request(:post, "#{BASE}/graphql/transactions")
      .with { |req| JSON.parse(req.body).dig("variables", "page") == 2 }
      .to_return(status: 200, body: page.call([], 150), headers: JSON_HEADERS)

    error = assert_raises(Provider::Stashaway::ApiError) { @provider.goal_transactions("g1") }

    assert_match "150", error.message
    assert_match "149", error.message
  end

  test "a goal with more pages than Sure reads is an error, not a shorter list" do
    stub_request(:post, "#{BASE}/graphql/transactions").to_return do |request|
      page = JSON.parse(request.body).dig("variables", "page")
      items = Array.new(100) { |i| { id: "p#{page}-#{i}" } }
      { status: 200, headers: JSON_HEADERS, body: { data: { goal: { _id: "g1", transactions: { count: 30_000, items: items } } } }.to_json }
    end

    error = assert_raises(Provider::Stashaway::ApiError) { @provider.goal_transactions("g1") }

    assert_match "g1", error.message
    assert_match "30000", error.message
    assert_match "20000", error.message
    assert_requested :post, "#{BASE}/graphql/transactions", times: 200
  end

  test "requests performance since inception in the display currency" do
    stub_request(:post, "#{BASE}/graphql/goals")
      .with { |req| JSON.parse(req.body)["variables"] == { "goalId" => "g1", "displayCurrency" => "USD" } && JSON.parse(req.body)["query"].include?("lookBackPeriod: INCEPTION") }
      .to_return(status: 200, body: { data: { goal: { portfolioPerformance: {
        lastNavUpdate: "2026-11-03", currency: "USD",
        netAssetValueData: [ { date: "2026-11-03T00:00:00.000Z", amount: 10 } ], netDepositsData: []
      } } } }.to_json, headers: JSON_HEADERS)

    performance = @provider.goal_performance("g1", "USD")

    assert_equal [ { "date" => "2026-11-03T00:00:00.000Z", "amount" => 10 } ], performance["nav"]
    assert_equal "2026-11-03", performance["last_nav_update"]
  end

  test "an expired token is an authentication error" do
    stub_request(:post, "#{BASE}/graphql/goals").to_return(status: 401, body: "")

    assert_raises(Provider::Stashaway::AuthenticationError) { @provider.goals }
  end

  test "a GraphQL unauthorised error is an authentication error" do
    stub_request(:post, "#{BASE}/graphql/goals")
      .to_return(status: 200, body: { errors: [ { message: "Unauthorized" } ] }.to_json, headers: JSON_HEADERS)

    assert_raises(Provider::Stashaway::AuthenticationError) { @provider.goals }
  end

  test "a GraphQL forbidden error about a goal is not an expired sign-in" do
    stub_request(:post, "#{BASE}/graphql/transactions")
      .to_return(status: 200, body: { errors: [ { message: "Forbidden" } ] }.to_json, headers: JSON_HEADERS)

    error = assert_raises(Provider::Stashaway::ApiError) { @provider.goal_transactions("g1") }
    assert_match "Forbidden", error.message
  end

  test "a goal StashAway cannot find is not found" do
    stub_request(:post, "#{BASE}/graphql/transactions")
      .to_return(status: 200, body: { errors: [ { message: "Goal not found" } ] }.to_json, headers: JSON_HEADERS)

    assert_raises(Provider::Stashaway::NotFound) { @provider.goal_transactions("closed") }
  end

  test "a GraphQL answer without data is an error, not an empty result" do
    stub_request(:post, "#{BASE}/graphql/goals")
      .to_return(status: 200, body: {}.to_json, headers: JSON_HEADERS).then
      .to_return(status: 200, body: { data: nil }.to_json, headers: JSON_HEADERS)

    assert_raises(Provider::Stashaway::ApiError) { @provider.goals }
    assert_raises(Provider::Stashaway::ApiError) { @provider.goals }
  end

  test "an outdated client id is reported as such" do
    stub_request(:post, "#{BASE}/graphql/goals").to_return(status: 426, body: "")

    error = assert_raises(Provider::Stashaway::UnsupportedClient) { @provider.goals }
    assert_match "webapp@4.4.0", error.message
  end

  test "a token is usable only when StashAway serves data for it" do
    stub_request(:post, "#{BASE}/graphql/goals").with(headers: { "Authorization" => "Bearer good" })
      .to_return(status: 200, body: { data: { goals: [] } }.to_json, headers: JSON_HEADERS)
    stub_request(:post, "#{BASE}/graphql/goals").with(headers: { "Authorization" => "Bearer unverified" })
      .to_return(status: 403, body: "")
    stub_request(:post, "#{BASE}/graphql/goals").with(headers: { "Authorization" => "Bearer refused" })
      .to_return(status: 200, body: { errors: [ { message: "Two-factor authentication required" } ] }.to_json, headers: JSON_HEADERS)

    client = Provider::Stashaway.new(region: "sg")
    assert client.usable_token?("good")
    assert_not client.usable_token?("unverified")
    assert_not client.usable_token?("refused")
  end

  test "an outage while checking a token is not taken for a refusal" do
    stub_request(:post, "#{BASE}/graphql/goals").to_return(status: 503, body: "")

    assert_raises(Provider::Stashaway::TransientError) { Provider::Stashaway.new(region: "sg").usable_token?("token") }
  end

  test "each region signs in and reads data on its own host" do
    { "sg" => "api.stashaway.sg", "my" => "api.stashaway.my", "hk" => "api.stashaway.hk",
      "ae" => "api.stashaway.ae", "th" => "api.stashaway.co.th" }.each do |region, host|
      login = stub_request(:post, "https://#{host}/api/v2/auth/login")
        .to_return(status: 200, body: { token: "login-token" }.to_json, headers: JSON_HEADERS)
      goals = stub_request(:post, "https://#{host}/graphql/goals")
        .to_return(status: 200, body: { data: { goals: [] } }.to_json, headers: JSON_HEADERS)

      Provider::Stashaway.new(region: region).login(email: "investor@example.com", password: "secret", device_id: "device-1")
      assert Provider::Stashaway.new(region: region).usable_token?("login-token")

      assert_requested login
      assert_requested goals
    end
  end

  test "an unknown region is refused" do
    assert_raises(ArgumentError) { Provider::Stashaway.new(region: "us") }
  end

  test "retries a dropped connection" do
    stub_request(:post, "#{BASE}/graphql/goals")
      .to_raise(Errno::ECONNRESET).then
      .to_return(status: 200, body: { data: { goals: [] } }.to_json, headers: JSON_HEADERS)

    assert_equal [], @provider.goals
  end

  test "a sign-in step whose answer is lost is not sent again" do
    verify = stub_request(:post, "#{BASE}/api/v1/auth/2fa").to_raise(Net::ReadTimeout)
    send = stub_request(:post, "#{BASE}/api/v1/auth/2fa/send").to_raise(Errno::ECONNRESET)
    client = Provider::Stashaway.new(region: "sg")

    assert_raises(Provider::Stashaway::TransientError) { client.verify_two_factor(code: "123456", token: "login-token", device_id: "device-1") }
    assert_raises(Provider::Stashaway::TransientError) { client.send_two_factor_code(token: "login-token") }
    assert_requested verify, times: 1
    assert_requested send, times: 1
  end

  test "a sign-in step that could not connect is tried once more" do
    login = stub_request(:post, "#{BASE}/api/v2/auth/login")
      .to_raise(Errno::ECONNREFUSED).then
      .to_return(status: 200, body: { token: "login-token" }.to_json, headers: JSON_HEADERS)

    session = Provider::Stashaway.new(region: "sg").login(email: "investor@example.com", password: "secret", device_id: "device-1")

    assert_equal "login-token", session.token
    assert_requested login, times: 2
  end

  test "a sign-in step that cannot connect twice gives up" do
    login = stub_request(:post, "#{BASE}/api/v2/auth/login").to_raise(SocketError)

    assert_raises(Provider::Stashaway::TransientError) do
      Provider::Stashaway.new(region: "sg").login(email: "investor@example.com", password: "secret", device_id: "device-1")
    end
    assert_requested login, times: 2
  end
end
