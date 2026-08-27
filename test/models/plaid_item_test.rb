require "test_helper"

class PlaidItemTest < ActiveSupport::TestCase
  include SyncableInterfaceTest

  setup do
    @plaid_item = @syncable = plaid_items(:one)
    @plaid_provider = mock
    Provider::Registry.stubs(:plaid_provider_for_region).returns(@plaid_provider)
  end

  test "removes plaid item when destroyed" do
    @plaid_provider.expects(:remove_item).with(@plaid_item.access_token).once

    assert_difference "PlaidItem.count", -1 do
      @plaid_item.destroy
    end
  end

  test "destroys item even when Plaid credentials are invalid" do
    error_response = {
      "error_code" => "INVALID_API_KEYS",
      "error_message" => "invalid client_id or secret provided"
    }.to_json

    plaid_error = Plaid::ApiError.new(code: 400, response_body: error_response)
    @plaid_provider.expects(:remove_item).raises(plaid_error)

    assert_difference "PlaidItem.count", -1 do
      @plaid_item.destroy
    end
  end

  test "destroys item even when Plaid item not found" do
    error_response = {
      "error_code" => "ITEM_NOT_FOUND",
      "error_message" => "item not found"
    }.to_json

    plaid_error = Plaid::ApiError.new(code: 400, response_body: error_response)
    @plaid_provider.expects(:remove_item).raises(plaid_error)

    assert_difference "PlaidItem.count", -1 do
      @plaid_item.destroy
    end
  end

  test "get_update_link_token marks item as requires_update and returns nil on ITEM_NOT_FOUND" do
    error_response = { "error_code" => "ITEM_NOT_FOUND", "error_message" => "not found" }.to_json
    Family.any_instance.expects(:get_link_token).raises(
      Plaid::ApiError.new(code: 400, response_body: error_response)
    )

    result = @plaid_item.get_update_link_token(webhooks_url: "https://x", redirect_url: "https://x")

    assert_nil result
    assert_predicate @plaid_item.reload, :requires_update?
  end

  test "get_update_link_token re-raises other Plaid errors so the controller can surface them" do
    # Issue #1792: silently swallowing all Plaid errors here is what made the
    # "modal closes with nothing happening" experience so opaque.
    error_response = { "error_code" => "INVALID_PRODUCT", "error_message" => "Your account is not enabled..." }.to_json
    Family.any_instance.expects(:get_link_token).raises(
      Plaid::ApiError.new(code: 400, response_body: error_response)
    )

    assert_raises(Plaid::ApiError) do
      @plaid_item.get_update_link_token(webhooks_url: "https://x", redirect_url: "https://x")
    end
    assert_predicate @plaid_item.reload, :good?
  end

  test "get_update_link_token tolerates a Plaid::ApiError with a nil/blank response_body" do
    # Plaid clients have been observed raising ApiError without a response
    # body (network-layer failures, early aborts). The old JSON.parse would
    # blow up with TypeError before the rescue could fire; we now coerce
    # to String so the parse falls back to {} and the error re-raises
    # cleanly for the controller to handle.
    Family.any_instance.expects(:get_link_token).raises(
      Plaid::ApiError.new(code: 500, response_body: nil)
    )

    assert_raises(Plaid::ApiError) do
      @plaid_item.get_update_link_token(webhooks_url: "https://x", redirect_url: "https://x")
    end
    assert_predicate @plaid_item.reload, :good?
  end

  test "user sync requests a provider refresh when cooldown lease is acquired" do
    Rails.cache.expects(:write).with(
      "plaid_item:#{@plaid_item.id}:transactions_refresh_requested",
      true,
      expires_in: PlaidItem::TRANSACTIONS_REFRESH_COOLDOWN,
      unless_exist: true
    ).returns(true)

    assert_enqueued_with(job: PlaidTransactionsRefreshJob, args: [ @plaid_item ]) do
      @plaid_item.request_transactions_refresh_later
    end
  end

  test "user sync does not duplicate a recent provider refresh request" do
    Rails.cache.stubs(:write).returns(false)

    assert_no_enqueued_jobs only: PlaidTransactionsRefreshJob do
      @plaid_item.request_transactions_refresh_later
    end
  end

  test "user sync does not request refresh without the transactions product" do
    @plaid_item.update!(billed_products: [ "investments" ])

    Rails.cache.expects(:write).never
    assert_no_enqueued_jobs only: PlaidTransactionsRefreshJob do
      @plaid_item.request_transactions_refresh_later
    end
  end

  test "user sync preserves immediate sync while requesting provider refresh" do
    @plaid_item.expects(:request_transactions_refresh_later).once
    @plaid_item.expects(:sync_later).once

    @plaid_item.sync_later_with_provider_refresh
  end
end
