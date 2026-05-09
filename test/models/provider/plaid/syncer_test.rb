require "test_helper"

# Targeted coverage for Provider::Plaid::Syncer's stale-account flagging.
# We don't exercise the full perform_sync (the AccountImporter / processor
# stack is heavy and tested elsewhere) — only the discovery-side disappeared
# logic, which mirrors Provider::Truelayer::Syncer's contract and shares the
# same Rails-7.2 `where.not(col: [])` guard.
class Provider::Plaid::SyncerTest < ActiveSupport::TestCase
  setup do
    @family = families(:empty)
    @connection = Provider::Connection.create!(
      family: @family, provider_key: "plaid", auth_type: "embedded_link",
      credentials: { "access_token" => "tok_test" }, status: :healthy,
      metadata: { "region" => "us" }
    )
    @pa = Provider::Account.create!(
      provider_connection: @connection,
      external_id:         "acc_existing",
      external_name:       "Checking",
      external_type:       "depository",
      external_subtype:    "checking",
      currency:            "USD",
      raw_payload:         {}
    )
    @syncer = Provider::Plaid::Syncer.new(@connection)
  end

  test "discover_accounts_only does NOT mark accounts disappeared on empty response with existing rows" do
    # Seen-IDs empty + provider_accounts.exists? must short-circuit, otherwise
    # `.where.not(external_id: [])` flips every row.
    snapshot = mock("AccountsSnapshot")
    snapshot.stubs(:accounts).returns([])
    Provider::Plaid::AccountsSnapshot.stubs(:new).returns(snapshot)

    item = OpenStruct.new(
      billed_products: [], available_products: [], institution_id: "ins_1"
    )
    item_response = OpenStruct.new(item: item)
    plaid_client = mock
    plaid_client.stubs(:get_item).returns(item_response)
    Provider::Registry.stubs(:plaid_provider_for_region).returns(plaid_client)

    @syncer.discover_accounts_only

    assert_not @pa.reload.disappeared?,
      "empty discovery + existing rows must not flip them to disappeared"
  end

  test "discover_accounts_only marks an account disappeared when missing from a non-empty response" do
    other = OpenStruct.new(
      account_id: "acc_other",
      name: "Savings", type: "depository", subtype: "savings",
      balances: OpenStruct.new(iso_currency_code: "USD", unofficial_currency_code: nil),
      to_hash: { "account_id" => "acc_other" }
    )
    snapshot = mock("AccountsSnapshot")
    snapshot.stubs(:accounts).returns([ other ])
    Provider::Plaid::AccountsSnapshot.stubs(:new).returns(snapshot)

    item = OpenStruct.new(
      billed_products: [], available_products: [], institution_id: "ins_1"
    )
    item_response = OpenStruct.new(item: item)
    plaid_client = mock
    plaid_client.stubs(:get_item).returns(item_response)
    Provider::Registry.stubs(:plaid_provider_for_region).returns(plaid_client)

    @syncer.discover_accounts_only

    assert @pa.reload.disappeared?,
      "previously-known account missing from discovery response should be flagged"
  end

  test "discover_accounts_only clears disappeared flag when an account comes back" do
    @pa.update!(raw_payload: @pa.raw_payload.merge("disappeared_at" => 1.day.ago.iso8601))
    raw = OpenStruct.new(
      account_id: @pa.external_id,
      name: @pa.external_name, type: @pa.external_type, subtype: @pa.external_subtype,
      balances: OpenStruct.new(iso_currency_code: @pa.currency, unofficial_currency_code: nil),
      to_hash: { "account_id" => @pa.external_id }
    )
    snapshot = mock("AccountsSnapshot")
    snapshot.stubs(:accounts).returns([ raw ])
    Provider::Plaid::AccountsSnapshot.stubs(:new).returns(snapshot)

    item = OpenStruct.new(
      billed_products: [], available_products: [], institution_id: "ins_1"
    )
    item_response = OpenStruct.new(item: item)
    plaid_client = mock
    plaid_client.stubs(:get_item).returns(item_response)
    Provider::Registry.stubs(:plaid_provider_for_region).returns(plaid_client)

    @syncer.discover_accounts_only

    assert_not @pa.reload.disappeared?
  end
end
