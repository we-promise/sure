require "test_helper"

class Provider::Plaid::AdapterTest < ActiveSupport::TestCase
  test "registered with ConnectionRegistry under plaid" do
    assert_equal Provider::Plaid::Adapter, Provider::ConnectionRegistry.adapter_for("plaid")
  end

  test "auth_class is EmbeddedLink" do
    assert_equal Provider::Auth::EmbeddedLink, Provider::Plaid::Adapter.auth_class
  end

  test "syncer_class is Provider::Plaid::Syncer" do
    assert_equal Provider::Plaid::Syncer, Provider::Plaid::Adapter.syncer_class
  end

  test "supported_account_types covers depository, credit, loan, investment" do
    assert_equal %w[Depository CreditCard Loan Investment],
                 Provider::Plaid::Adapter.supported_account_types
  end

  test "build_sure_account maps depository to Depository with subtype" do
    family = families(:empty)
    pa = build_provider_account(external_type: "depository", external_subtype: "checking",
                                external_name: "Chase Checking", currency: "USD")
    account = Provider::Plaid::Adapter.build_sure_account(pa, family: family)
    assert_instance_of Depository, account.accountable
    assert_equal "checking", account.accountable.subtype
    assert_equal "Chase Checking", account.name
    assert_equal "USD", account.currency
  end

  test "build_sure_account maps credit to CreditCard" do
    pa = build_provider_account(external_type: "credit", external_subtype: "credit card",
                                external_name: "Chase CC", currency: "USD")
    account = Provider::Plaid::Adapter.build_sure_account(pa, family: families(:empty))
    assert_instance_of CreditCard, account.accountable
    assert_equal "credit_card", account.accountable.subtype
  end

  test "build_sure_account maps investment with brokerage subtype" do
    pa = build_provider_account(external_type: "investment", external_subtype: "brokerage",
                                external_name: "Fidelity", currency: "USD")
    account = Provider::Plaid::Adapter.build_sure_account(pa, family: families(:empty))
    assert_instance_of Investment, account.accountable
    assert_equal "brokerage", account.accountable.subtype
  end

  test "build_sure_account maps loan with mortgage subtype" do
    pa = build_provider_account(external_type: "loan", external_subtype: "mortgage",
                                external_name: "Mortgage", currency: "USD")
    account = Provider::Plaid::Adapter.build_sure_account(pa, family: families(:empty))
    assert_instance_of Loan, account.accountable
    assert_equal "mortgage", account.accountable.subtype
  end

  test "build_sure_account raises for unknown external_type" do
    pa = build_provider_account(external_type: "crypto", external_subtype: nil,
                                external_name: "?", currency: "USD")
    assert_raises(Provider::Account::UnsupportedAccountableType) do
      Provider::Plaid::Adapter.build_sure_account(pa, family: families(:empty))
    end
  end

  test "build_sure_account falls back to 'other' subtype for unknown subtype" do
    pa = build_provider_account(external_type: "depository", external_subtype: "unknown_subtype",
                                external_name: "Mystery", currency: "USD")
    account = Provider::Plaid::Adapter.build_sure_account(pa, family: families(:empty))
    assert_equal "other", account.accountable.subtype
  end

  test "humanize_link_error returns nil for non-Plaid exceptions" do
    err = StandardError.new("not a plaid error")
    assert_nil Provider::Plaid::Adapter.humanize_link_error(err, redirect_uri: "https://example.com/r/")
  end

  test "humanize_link_error returns structured OAuth-redirect-uri guidance with the URL exposed for copy" do
    body = {
      "error_code"    => "INVALID_FIELD",
      "error_message" => "OAuth redirect URI must be configured in the developer dashboard."
    }.to_json
    err = Plaid::ApiError.new(response_body: body)
    result = Provider::Plaid::Adapter.humanize_link_error(err, redirect_uri: "https://app.example.com/provider_connections/plaid/auth/redirect/")

    assert_equal "https://app.example.com/provider_connections/plaid/auth/redirect/", result["redirect_uri"]
    assert_match "OAuth redirect URI", result["message"]
    assert_match "Plaid Dashboard", result["message"]
  end

  test "humanize_link_error falls back to message-only hash for other Plaid errors" do
    body = { "error_code" => "ITEM_LOGIN_REQUIRED", "error_message" => "User needs to re-auth." }.to_json
    err = Plaid::ApiError.new(response_body: body)
    result = Provider::Plaid::Adapter.humanize_link_error(err, redirect_uri: "https://x")
    assert_equal({ "message" => "Plaid: User needs to re-auth." }, result)
  end

  test "humanize_link_error degrades gracefully when Plaid response body is unparseable" do
    err = Plaid::ApiError.new(response_body: "<html>nginx error</html>")
    result = Provider::Plaid::Adapter.humanize_link_error(err, redirect_uri: "https://x")
    assert_match(/Plaid returned an error/, result["message"])
    assert_nil result["redirect_uri"]
  end

  private

    def build_provider_account(external_type:, external_subtype:, external_name:, currency:)
      conn = Provider::Connection.create!(
        family: families(:empty), provider_key: "plaid",
        auth_type: "embedded_link", credentials: {}, status: :healthy,
        metadata: { "region" => "us" }
      )
      Provider::Account.create!(
        provider_connection: conn,
        external_id:         "acc_#{SecureRandom.hex(4)}",
        external_name:       external_name,
        external_type:       external_type,
        external_subtype:    external_subtype,
        currency:            currency,
        raw_payload:         {}
      )
    end
end
