require "test_helper"

class FamilyResetJobTest < ActiveJob::TestCase
  setup do
    @family = families(:dylan_family)
    @plaid_provider = mock
    Provider::Registry.stubs(:plaid_provider_for_region).returns(@plaid_provider)
  end

  test "resets family data successfully" do
    initial_account_count = @family.accounts.count
    initial_category_count = @family.categories.count

    # Family should have existing data
    assert initial_account_count > 0
    assert initial_category_count > 0

    # Don't expect Plaid removal calls since we're using fixtures without setup
    @plaid_provider.stubs(:remove_item)

    FamilyResetJob.perform_now(@family)

    # All data should be removed
    assert_equal 0, @family.accounts.reload.count
    assert_equal 0, @family.categories.reload.count
  end

  test "resets family data even when Plaid credentials are invalid" do
    # Use existing plaid item from fixtures
    plaid_item = plaid_items(:one)
    assert_equal @family, plaid_item.family

    initial_plaid_count = @family.plaid_items.count
    assert initial_plaid_count > 0

    # Simulate invalid Plaid credentials error
    error_response = {
      "error_code" => "INVALID_API_KEYS",
      "error_message" => "invalid client_id or secret provided"
    }.to_json

    plaid_error = Plaid::ApiError.new(code: 400, response_body: error_response)
    @plaid_provider.expects(:remove_item).raises(plaid_error)

    # Job should complete successfully despite the Plaid error
    assert_nothing_raised do
      FamilyResetJob.perform_now(@family)
    end

    # PlaidItem should be deleted
    assert_equal 0, @family.plaid_items.reload.count
  end
end
