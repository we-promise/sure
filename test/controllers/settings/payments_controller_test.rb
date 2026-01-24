require "test_helper"

class Settings::PaymentsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:empty)
    @family = @user.family
  end

  test "returns forbidden when family has no stripe_customer_id" do
    assert_nil @family.stripe_customer_id

    get settings_payment_path
    assert_response :forbidden
  end

  test "shows payment settings when family has stripe_customer_id" do
    @family.update!(stripe_customer_id: "cus_test123")

    get settings_payment_path
    assert_response :success
  end
end
