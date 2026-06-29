require "test_helper"

class Transactions::UpcomingsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in users(:family_admin)
  end

  test "show returns upcoming panel in turbo frame" do
    get upcoming_transactions_url

    assert_response :success
    assert_select "turbo-frame#transactions-upcoming"
  end
end
