require "test_helper"

class Provider::AccountTest < ActiveSupport::TestCase
  test "belongs to connection" do
    pa = provider_accounts(:monzo_current)
    assert_equal provider_connections(:monzo_connection), pa.provider_connection
  end

  test "linked? when account present" do
    assert provider_accounts(:monzo_current).linked?
  end

  test "linked? returns false when no account" do
    assert_not provider_accounts(:monzo_unlinked).linked?
  end

  test "requires external_id uniqueness per connection" do
    pa = Provider::Account.new(
      provider_connection: provider_connections(:monzo_connection),
      external_id: "acc_abc123",
      raw_payload: {}
    )
    assert_not pa.valid?
  end

  setup do
    @family = families(:dylan_family)
    @pa     = provider_accounts(:monzo_unlinked)
  end

  test "build_sure_account builds a Depository for depository external_type" do
    @pa.update!(external_type: "depository", external_subtype: "checking",
                external_name: "Monzo Current Account", currency: "GBP")
    account = @pa.build_sure_account(family: @family)
    assert_instance_of Depository, account.accountable
    assert_equal "checking", account.accountable.subtype
    assert_equal "Monzo Current Account", account.name
    assert_equal "GBP", account.currency
    assert_equal 0, account.balance
  end

  test "build_sure_account builds a CreditCard for credit external_type" do
    @pa.update!(external_type: "credit", external_subtype: "credit_card",
                external_name: "Amex Platinum", currency: "GBP")
    account = @pa.build_sure_account(family: @family)
    assert_instance_of CreditCard, account.accountable
  end

  test "build_sure_account raises for unknown external_type rather than silently mis-categorizing" do
    @pa.update!(external_type: "investment", external_name: "Mystery Account",
                currency: "GBP")
    error = assert_raises(Provider::Account::UnsupportedAccountableType) do
      @pa.build_sure_account(family: @family)
    end
    assert_match(/external_type=/, error.message)
  end

  test "build_sure_account returns an unsaved record" do
    account = @pa.build_sure_account(family: @family)
    assert account.new_record?
  end

  test "build_sure_account produces a valid saveable account" do
    account = @pa.build_sure_account(family: @family)
    assert account.save, account.errors.full_messages.to_s
  end

  test "unlinked_and_unskipped excludes skipped accounts" do
    family = families(:empty)
    conn = Provider::Connection.create!(
      family: family, provider_key: "truelayer", auth_type: "oauth2",
      credentials: {}, status: :healthy
    )
    unlinked = Provider::Account.create!(
      provider_connection: conn, external_id: "acc_1",
      external_name: "Current", external_type: "depository", currency: "GBP"
    )
    skipped = Provider::Account.create!(
      provider_connection: conn, external_id: "acc_2",
      external_name: "Savings", external_type: "depository", currency: "GBP",
      skipped: true
    )

    result_ids = conn.provider_accounts.unlinked_and_unskipped.pluck(:id)
    assert_includes result_ids, unlinked.id
    assert_not_includes result_ids, skipped.id
  end

  test "pending_setup? ignores skipped accounts" do
    family = families(:empty)
    conn = Provider::Connection.create!(
      family: family, provider_key: "truelayer", auth_type: "oauth2",
      credentials: {}, status: :healthy
    )
    Provider::Account.create!(
      provider_connection: conn, external_id: "acc_skipped",
      external_name: "Savings", external_type: "depository", currency: "GBP",
      skipped: true
    )
    assert_not conn.pending_setup?, "should not be pending when only account is skipped"
  end

  test "safe_logo_uri returns https URL from raw_payload" do
    @pa.update!(raw_payload: { "provider" => { "logo_uri" => "https://cdn.example.com/logo.svg" } })
    assert_equal "https://cdn.example.com/logo.svg", @pa.safe_logo_uri
  end

  test "safe_logo_uri rejects http (non-TLS) URLs" do
    @pa.update!(raw_payload: { "provider" => { "logo_uri" => "http://cdn.example.com/logo.svg" } })
    assert_nil @pa.safe_logo_uri
  end

  test "safe_logo_uri rejects javascript: scheme" do
    @pa.update!(raw_payload: { "provider" => { "logo_uri" => "javascript:alert(1)" } })
    assert_nil @pa.safe_logo_uri
  end

  test "safe_logo_uri returns nil when raw_payload missing logo_uri" do
    @pa.update!(raw_payload: { "provider" => { "display_name" => "Bank" } })
    assert_nil @pa.safe_logo_uri
  end

  test "safe_logo_uri returns nil for malformed URI" do
    @pa.update!(raw_payload: { "provider" => { "logo_uri" => "not a url" } })
    assert_nil @pa.safe_logo_uri
  end

  test "disappeared? returns true when raw_payload has disappeared_at" do
    @pa.update!(raw_payload: @pa.raw_payload.merge("disappeared_at" => Time.current.iso8601))
    assert @pa.disappeared?
  end

  test "disappeared? returns false when raw_payload missing disappeared_at" do
    @pa.update!(raw_payload: @pa.raw_payload.except("disappeared_at"))
    assert_not @pa.disappeared?
  end

  test "disappeared_at parses iso8601 timestamp from raw_payload" do
    ts = "2026-04-01T12:00:00Z"
    @pa.update!(raw_payload: @pa.raw_payload.merge("disappeared_at" => ts))
    assert_equal Time.parse(ts), @pa.disappeared_at
  end

  test "disappeared_at returns nil for malformed timestamp" do
    @pa.update!(raw_payload: @pa.raw_payload.merge("disappeared_at" => "not a date"))
    assert_nil @pa.disappeared_at
  end
end
