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
    stripe = mock
    stripe.expects(:payment_link_url).returns("https://buy.stripe.com/test_payment_link")
    Provider::Registry.stubs(:get_provider).with(:stripe).returns(stripe)

    get settings_payment_path
    assert_response :success
    assert_select(
      "a[href=?]",
      "https://buy.stripe.com/test_payment_link",
      text: I18n.t("views.settings.payments.show.one_time_contribution_link_text")
    )
  end
end
