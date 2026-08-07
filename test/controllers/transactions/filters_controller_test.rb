require "test_helper"

class Transactions::FiltersControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
  end

  test "renders the filter menu inside the lazy-loaded turbo frame" do
    get filters_transactions_url, headers: { "Turbo-Frame" => "transaction-filters" }

    assert_response :success
    assert_select "turbo-frame#transaction-filters" do
      assert_select "#transaction-filters-menu"
    end
  end

  test "preserves active filters as checked state" do
    account = @user.accessible_accounts.alphabetically.first

    get filters_transactions_url(q: { accounts: [ account.name ] }),
        headers: { "Turbo-Frame" => "transaction-filters" }

    assert_response :success
    assert_select "input[type=checkbox][name='q[accounts][]'][value='#{account.name}'][checked]"
  end

  test "requires authentication" do
    delete session_url(sessions(:one)) rescue nil
    reset!

    get filters_transactions_url
    assert_redirected_to new_session_url
  end
end
