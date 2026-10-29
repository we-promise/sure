require "application_system_test_case"
require Rails.root.join("test/support/web_push_test_helper")

class WebPushNotificationsTest < ApplicationSystemTestCase
  include WebPushTestHelper

  setup do
    @user = users(:family_admin)
    enable_web_push_preview(@user)
    WebPush::Client.stubs(:configured?).returns(true)
    WebPush::Client.stubs(:vapid).returns(public_key: Base64.urlsafe_encode64("a" * 65, padding: false))
    sign_in @user
  end

  test "explicit device controls register test and remove only this browser" do
    attributes = web_push_attributes
    visit settings_preferences_path
    assert_selector "[data-controller='web-push']"
    install_browser_push_double(attributes)

    assert_equal 0, page.evaluate_script("window.pushTest.permissionRequests")
    click_on I18n.t("web_push.enable")
    assert_text I18n.t("web_push.status.enabled")
    assert_equal 1, page.evaluate_script("window.pushTest.permissionRequests")
    device = @user.web_push_subscriptions.find_by!(endpoint_digest: Digest::SHA256.hexdigest(attributes[:endpoint]))

    click_on I18n.t("web_push.test")
    assert_text I18n.t("web_push.status.queued")
    delivery = device.web_push_deliveries.where(insight_id: nil).last!
    client = mock
    WebPush::Client.expects(:new).returns(client)
    client.expects(:deliver).returns(:accepted)
    DeliverWebPushNotificationJob.perform_now(web_push_delivery_id: delivery.id)
    assert_text I18n.t("web_push.status.accepted"), wait: 10

    click_on I18n.t("web_push.disable")
    assert_text I18n.t("web_push.status.disabled")
    assert_not WebPushSubscription.exists?(device.id)
    assert_equal true, page.evaluate_script("window.pushTest.unsubscribed")
  end

  test "budget warning opt in is saved independently from device registration" do
    visit settings_preferences_path
    find("label[for='user_web_push_budget_warnings_enabled']").click
    assert_selector "#user_web_push_budget_warnings_enabled[checked]"
    assert @user.reload.web_push_budget_warnings_enabled?
    assert_empty @user.web_push_subscriptions
  end

  private
    # Browser/OS push permission is outside Selenium's portable API. Replace that
    # boundary only; clicks, CSRF, Rails registration, status polling and deletion
    # still use the real application. This does not prove phone presentation.
    def install_browser_push_double(attributes)
      script = <<~JS
        const attributes = arguments[0];
        const complete = arguments[arguments.length - 1];
        const element = document.querySelector('[data-controller="web-push"]');
        const controller = window.Stimulus.getControllerForElementAndIdentifier(element, "web-push");
        window.pushTest = { permissionRequests: 0, unsubscribed: false, current: null };
        const device = {
          toJSON: () => ({ endpoint: attributes.endpoint, keys: { p256dh: attributes.p256dh, auth: attributes.auth } }),
          unsubscribe: async () => { window.pushTest.unsubscribed = true; window.pushTest.current = null; return true; }
        };
        const registration = { pushManager: {
          getSubscription: async () => window.pushTest.current,
          subscribe: async () => { window.pushTest.current = device; return device; }
        } };
        Object.defineProperty(window, "isSecureContext", { configurable: true, value: true });
        Object.defineProperty(window, "PushManager", { configurable: true, value: function() {} });
        Object.defineProperty(window, "Notification", { configurable: true, value: {
          permission: "default",
          requestPermission: async () => { window.pushTest.permissionRequests++; window.Notification.permission = "granted"; return "granted"; }
        } });
        Object.defineProperty(navigator, "serviceWorker", { configurable: true, value: {
          getRegistration: async () => registration,
          register: async () => registration,
          ready: Promise.resolve(registration)
        } });
        controller.connect().then(complete);
      JS
      page.execute_async_script(script, attributes.stringify_keys)
    end
end
