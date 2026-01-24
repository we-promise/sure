require "test_helper"
require "ostruct"

class SubscriptionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:empty)
    @family = @user.family

    @mock_stripe = mock
    Provider::Registry.stubs(:get_provider).with(:stripe).returns(@mock_stripe)
  end

  test "disabled for self hosted users" do
    with_self_hosting do
      post subscription_path
      assert_response :forbidden
    end
  end

  # Trial subscriptions are managed internally and do NOT go through Stripe
  test "can create trial subscription" do
    @family.subscription.destroy
    @family.reload

    assert_difference "Subscription.count", 1 do
      post subscription_path
    end

    assert_redirected_to root_path
    assert_equal "Welcome to Sure!", flash[:notice]
    assert_equal "trialing", @family.subscription.status
    assert_in_delta Subscription::TRIAL_DAYS.days.from_now, @family.subscription.trial_ends_at, 1.minute
  end

  test "users who have already trialed cannot create a new subscription" do
    assert_no_difference "Subscription.count" do
      post subscription_path
    end

    assert_redirected_to root_path
    assert_equal "You have already started or completed a trial. Please upgrade to continue.", flash[:alert]
  end

  test "creates new checkout session" do
    @mock_stripe.expects(:create_checkout_session).with(
      plan: "monthly",
      family_id: @family.id,
      family_email: @family.payment_email,
      success_url: success_subscription_url + "?session_id={CHECKOUT_SESSION_ID}",
      cancel_url: upgrade_subscription_url
    ).returns(
      OpenStruct.new(
        url: "https://checkout.stripe.com/c/pay/test-session-id",
        customer_id: "test-customer-id"
      )
    )

    get new_subscription_path(plan: "monthly")

    assert_redirected_to "https://checkout.stripe.com/c/pay/test-session-id"
    assert_equal "test-customer-id", @family.reload.stripe_customer_id
  end

  test "creates active subscription on checkout success" do
    @mock_stripe.expects(:get_checkout_result).with("test-session-id").returns(
      OpenStruct.new(
        success?: true,
        subscription_id: "test-subscription-id"
      )
    )

    get success_subscription_url(session_id: "test-session-id")

    assert @family.subscription.active?
    assert_equal "Welcome to Sure!  Your contribution is appreciated.", flash[:notice]
  end

  test "show action returns forbidden when family has no stripe_customer_id" do
    assert_nil @family.stripe_customer_id

    get subscription_path
    assert_response :forbidden
  end

  test "show action redirects to stripe portal when family has stripe_customer_id" do
    @family.update!(stripe_customer_id: "cus_test123")

    @mock_stripe.expects(:create_payment_portal_session_url).with(
      customer_id: "cus_test123",
      return_url: settings_payment_url
    ).returns("https://billing.stripe.com/session/test")

    get subscription_path
    assert_redirected_to "https://billing.stripe.com/session/test"
  end
end
