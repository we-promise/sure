require "test_helper"
require Rails.root.join("test/support/web_push_test_helper")

class WebPushSubscriptionsControllerTest < ActionDispatch::IntegrationTest
  include WebPushTestHelper

  setup do
    @user = users(:family_admin)
    enable_web_push_preview(@user)
    sign_in @user
    @session = Current.session
    @attributes = web_push_attributes
    WebPush::Client.stubs(:configured?).returns(true)
  end

  test "registration requires an authenticated cookie session" do
    delete session_url(@session)
    post "/web_push_subscriptions", params: @attributes, as: :json
    assert_redirected_to new_session_url
  end

  test "registration requires preview opt in" do
    @user.update!(preferences: {})
    assert_no_difference "WebPushSubscription.count" do
      post "/web_push_subscriptions", params: @attributes, as: :json
      assert_response :forbidden
    end
  end

  test "registers for the current session in self hosted mode without a backlog" do
    Rails.application.config.stubs(:app_mode).returns("self_hosted".inquiry)
    assert_no_enqueued_jobs do
      assert_difference "WebPushSubscription.count", 1 do
        post "/web_push_subscriptions", params: @attributes, as: :json
      end
    end
    assert_response :created
    subscription = WebPushSubscription.find(response.parsed_body.fetch("id"))
    assert_equal @user.id, subscription.user_id
    assert_equal @session.id, subscription.session_id
    assert_not_includes response.body, @attributes[:endpoint]
    assert_not_includes response.body, @attributes[:auth]
  end

  test "registration is unavailable without VAPID configuration" do
    WebPush::Client.stubs(:configured?).returns(false)
    post "/web_push_subscriptions", params: @attributes, as: :json
    assert_response :service_unavailable
  end

  test "rejects invalid subscriptions without persisting them" do
    assert_no_difference "WebPushSubscription.count" do
      post "/web_push_subscriptions", params: @attributes.merge(endpoint: "https://localhost/private"), as: :json
      assert_response :unprocessable_entity
    end
  end

  test "cannot delete or test a different session's device" do
    other = register_web_push(user: @user)
    delete "/web_push_subscriptions/#{other.id}", as: :json
    assert_response :not_found
    post "/web_push_subscriptions/#{other.id}/test_notification", as: :json
    assert_response :not_found
    assert WebPushSubscription.exists?(other.id)
  end

  test "removes only the current device" do
    device = register_web_push(user: @user, session: @session)
    delete "/web_push_subscriptions/#{device.id}", as: :json
    assert_response :no_content
    assert_not WebPushSubscription.exists?(device.id)
  end

  test "testing the current device reports queued rather than provider accepted and is throttled" do
    device = register_web_push(user: @user, session: @session)
    assert_enqueued_jobs 1, only: DeliverWebPushNotificationJob do
      post "/web_push_subscriptions/#{device.id}/test_notification", as: :json
      assert_response :accepted
      assert_equal "queued", response.parsed_body.fetch("status")
      post "/web_push_subscriptions/#{device.id}/test_notification", as: :json
      assert_response :too_many_requests
    end
  end

  test "web registration retains Rails CSRF protection" do
    previous = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    post "/web_push_subscriptions", params: @attributes, as: :json
    assert_response :unprocessable_entity
  ensure
    ActionController::Base.allow_forgery_protection = previous
  end
end
