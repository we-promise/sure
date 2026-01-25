require "test_helper"
require "ostruct"

class Provider::Stripe::SubscriptionEventProcessorTest < ActiveSupport::TestCase
  test "handles subscription event" do
    test_customer_id = "test-customer-id"
    test_subscription_id = "test-subscription-id"

    mock_event = JSON.parse({
      type: "customer.subscription.created",
      data: {
        object: {
          id: test_subscription_id,
          status: "active",
          customer: test_customer_id,
          cancel_at_period_end: false,
          items: {
            data: [
              {
                current_period_end: 1.month.from_now.to_i,
                plan: {
                  interval: "month",
                  amount: 900,
                  currency: "usd"
                }
              }
            ]
          }
        }
      }
    }.to_json, object_class: OpenStruct)

    family = Family.create!(
      name: "Test Subscribed Family",
      stripe_customer_id: test_customer_id
    )

    family.start_subscription!(test_subscription_id)

    processor = Provider::Stripe::SubscriptionEventProcessor.new(mock_event)

    assert_equal "active", family.subscription.status
    assert_equal test_subscription_id, family.subscription.stripe_id
    assert_nil family.subscription.amount
    assert_nil family.subscription.currency
    assert_nil family.subscription.current_period_ends_at

    processor.process

    family.reload

    assert_equal "active", family.subscription.status
    assert_equal test_subscription_id, family.subscription.stripe_id
    assert_equal 9, family.subscription.amount
    assert_equal "USD", family.subscription.currency
    assert family.subscription.current_period_ends_at > 20.days.from_now
    assert_equal false, family.subscription.cancel_at_period_end
  end

  test "handles subscription cancellation at period end" do
    test_customer_id = "test-customer-id-cancel"
    test_subscription_id = "test-subscription-id-cancel"

    mock_event = JSON.parse({
      type: "customer.subscription.updated",
      data: {
        object: {
          id: test_subscription_id,
          status: "active",
          customer: test_customer_id,
          cancel_at_period_end: true,
          items: {
            data: [
              {
                current_period_end: 1.month.from_now.to_i,
                plan: {
                  interval: "month",
                  amount: 900,
                  currency: "usd"
                }
              }
            ]
          }
        }
      }
    }.to_json, object_class: OpenStruct)

    family = Family.create!(
      name: "Test Cancelling Family",
      stripe_customer_id: test_customer_id
    )

    family.start_subscription!(test_subscription_id)

    processor = Provider::Stripe::SubscriptionEventProcessor.new(mock_event)
    processor.process

    family.reload

    assert_equal "active", family.subscription.status
    assert_equal true, family.subscription.cancel_at_period_end
    assert family.subscription.pending_cancellation?
    assert family.subscription_pending_cancellation?
  end
end
