require "test_helper"

class Provider::YaxiTest < ActiveSupport::TestCase
  setup do
    @secret_bytes = "s" * 32
    @secret = Base64.strict_encode64(@secret_bytes)
    @provider = Provider::Yaxi.new(key_id: "api-key-test", secret: @secret, environment: "integration")
  end

  test "issues a signed short-lived service ticket" do
    expires_at = 5.minutes.from_now
    ticket = @provider.issue_ticket(
      ticket_id: "ticket-1",
      service: "Transactions",
      data: { account: { iban: "DE123", currency: "EUR" } },
      expires_at: expires_at
    )

    payload, header = JWT.decode(ticket.token, @secret_bytes, true, algorithms: [ "HS256" ])

    assert_equal "api-key-test", header.fetch("kid")
    assert_equal "Transactions", payload.dig("data", "service")
    assert_equal "ticket-1", payload.dig("data", "id")
    assert_equal "DE123", payload.dig("data", "data", "account", "iban")
    assert_equal expires_at.to_i, payload.fetch("exp")
  end

  test "verifies a result signature and ticket identifier" do
    result = result_token(ticket_id: "ticket-1", data: [ { "iban" => "DE123" } ])

    verified = @provider.verify_result(result, expected_ticket_id: "ticket-1")

    assert_equal [ { "iban" => "DE123" } ], verified.fetch("data")
  end

  test "rejects a result for another ticket" do
    result = result_token(ticket_id: "ticket-2", data: [])

    assert_raises(Provider::Yaxi::InvalidResultError) do
      @provider.verify_result(result, expected_ticket_id: "ticket-1")
    end
  end

  test "rejects a result signed with another secret" do
    result = result_token(ticket_id: "ticket-1", data: [], secret: "x" * 32)

    assert_raises(Provider::Yaxi::InvalidResultError) do
      @provider.verify_result(result, expected_ticket_id: "ticket-1")
    end
  end

  test "rejects a result signed by another key" do
    result = result_token(ticket_id: "ticket-1", data: [], key_id: "api-key-other")

    assert_raises(Provider::Yaxi::InvalidResultError) do
      @provider.verify_result(result, expected_ticket_id: "ticket-1")
    end
  end

  test "rejects an expired result" do
    result = result_token(ticket_id: "ticket-1", data: [], expires_at: 1.minute.ago)

    assert_raises(Provider::Yaxi::InvalidResultError) do
      @provider.verify_result(result, expected_ticket_id: "ticket-1")
    end
  end

  test "rejects invalid configuration" do
    assert_raises(Provider::Yaxi::InvalidConfigurationError) do
      Provider::Yaxi.new(key_id: "", secret: Base64.strict_encode64("short"))
    end
  end

  test "uses the integration endpoint when configured" do
    assert_equal "https://integration.yaxi.tech/", @provider.base_url
  end

  test "rejects an unsupported environment instead of falling back to production" do
    assert_raises(Provider::Yaxi::InvalidConfigurationError) do
      Provider::Yaxi.new(key_id: "api-key-test", secret: @secret, environment: "integation")
    end
  end

  test "adapter treats invalid Base64 as unconfigured" do
    stub_adapter_configuration(secret: "not-base64")

    assert_not Provider::YaxiAdapter.configured?
    assert_nil Provider::YaxiAdapter.build_provider
  end

  test "adapter treats a short decoded secret as unconfigured" do
    stub_adapter_configuration(secret: Base64.strict_encode64("short"))

    assert_not Provider::YaxiAdapter.configured?
    assert_nil Provider::YaxiAdapter.build_provider
  end

  test "adapter treats an unsupported environment as unconfigured" do
    stub_adapter_configuration(environment: "integation")

    assert_not Provider::YaxiAdapter.configured?
    assert_nil Provider::YaxiAdapter.build_provider
  end

  test "adapter builds a provider from valid configuration" do
    stub_adapter_configuration

    assert Provider::YaxiAdapter.configured?
    assert_instance_of Provider::Yaxi, Provider::YaxiAdapter.build_provider
  end

  test "translates provider configuration for the current locale" do
    configuration = Provider::YaxiAdapter.configuration
    key_id = configuration.fields.find { |field| field.name == :key_id }

    assert_equal "API key ID", I18n.with_locale(:en) { key_id.label }
    assert_equal "API-Key-ID", I18n.with_locale(:de) { key_id.label }
    assert_match "Connect European", I18n.with_locale(:en) { configuration.provider_description }
    assert_match "Verbinde europäische", I18n.with_locale(:de) { configuration.provider_description }
  end

  private

    def stub_adapter_configuration(secret: @secret, environment: "integration")
      Provider::YaxiAdapter.configuration.stubs(:configured?).returns(true)
      Provider::YaxiAdapter.stubs(:config_value).with(:key_id).returns("api-key-test")
      Provider::YaxiAdapter.stubs(:config_value).with(:secret).returns(secret)
      Provider::YaxiAdapter.stubs(:config_value).with(:environment).returns(environment)
    end

    def result_token(ticket_id:, data:, secret: @secret_bytes, key_id: "api-key-test", expires_at: 5.minutes.from_now)
      JWT.encode(
        { data: { data: data, ticketId: ticket_id, timestamp: Time.current.iso8601 }, exp: expires_at.to_i },
        secret,
        "HS256",
        { kid: key_id }
      )
    end
end
