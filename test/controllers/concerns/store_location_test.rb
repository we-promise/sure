require "test_helper"

class StoreLocationTest < ActionDispatch::IntegrationTest
  setup do
    sign_in users(:family_admin)
  end

  test "stores a short return_to with its query string" do
    return_to = transactions_path(q: { search: "coffee" })

    get accounts_path(return_to: return_to)

    assert_response :success
    assert_equal return_to, session[:return_to]
  end

  test "drops the query string of a return_to too long for the session cookie" do
    account_ids = Array.new(32) { SecureRandom.uuid }
    return_to = "/transactions?" + { page: 1, q: { account_ids: account_ids } }.to_query

    get accounts_path(return_to: return_to)

    assert_response :success
    assert_equal "/transactions", session[:return_to]
  end
end
