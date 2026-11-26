require "test_helper"

class Settings::PurchaseInboxesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:family_admin)
    @admin.update!(role: :super_admin, preferences: @admin.preferences.merge("preview_features_enabled" => true))
    sign_in @admin
    Rails.configuration.stubs(:app_mode).returns("self_hosted".inquiry)
    ApplicationController.any_instance.stubs(:redis_connected?).returns(true)
  end

  teardown do
    %i[purchase_inbox_enabled purchase_inbox_host purchase_inbox_username purchase_inbox_password
       purchase_inbox_authserv_id purchase_inbox_shop_domains].each { |field| Setting.public_send("#{field}=", nil) }
  end

  test "shows the mailbox settings, users' addresses and recently rejected emails" do
    Setting.purchase_inbox_username = "orders@example.com"
    DebugLogEntry.capture(category: "purchase_inbox", level: "info", message: "Order email rejected: unknown_sender",
                          source: "PurchasesMailbox", metadata: { reason: "unknown_sender", from: "spam@example.com", subject: "Win a prize" })

    get settings_purchase_inbox_url

    assert_response :success
    assert_includes response.body, "bob@bobdylan.com"
    assert_includes response.body, "orders+bob@example.com"
    assert_includes response.body, "spam@example.com"
    assert_includes response.body, "Win a prize"
  end

  test "never renders the stored password" do
    Setting.purchase_inbox_password = "s3cret-pass"

    get settings_purchase_inbox_url

    refute_includes response.body, "s3cret-pass"
  end

  test "is forbidden when not self-hosted" do
    Rails.configuration.stubs(:app_mode).returns("managed".inquiry)

    get settings_purchase_inbox_url

    assert_response :forbidden
  end

  test "needs preview features" do
    @admin.update!(preferences: @admin.preferences.merge("preview_features_enabled" => false))

    get settings_purchase_inbox_url

    assert_redirected_to root_path
  end

  test "a member who isn't an admin is turned away" do
    member = users(:family_member)
    member.update!(preferences: member.preferences.merge("preview_features_enabled" => true))
    sign_in member

    get settings_purchase_inbox_url

    assert_redirected_to settings_profile_path
  end

  test "a family admin who can't manage instance settings can't see the page" do
    @admin.update!(role: :admin)
    User.any_instance.stubs(:manages_instance_settings?).returns(false)
    DebugLogEntry.capture(category: "purchase_inbox", level: "info", message: "Order email rejected: unknown_sender",
                          source: "PurchasesMailbox", metadata: { reason: "unknown_sender", from: "other-family@example.com" })

    get settings_purchase_inbox_url

    assert_redirected_to settings_profile_path
  end

  test "update stores the connection and keeps the password when left blank" do
    patch settings_purchase_inbox_url, params: { setting: {
      host: "imap.example.com", port: "993", ssl: "1", username: "orders@example.com", password: "first",
      folder: "INBOX", processed_folder: "Sure/Done", shop_domains: "Amazon.com, allegro.pl", authserv_id: "MX.Google.com",
      require_sender_auth: "1"
    } }
    assert_redirected_to settings_purchase_inbox_url

    patch settings_purchase_inbox_url, params: { setting: { host: "imap.example.com", password: "" } }

    assert_equal "first", Setting.purchase_inbox_password
    assert_equal %w[amazon.com allegro.pl], Setting.purchase_inbox_shop_domains
    assert_equal "Sure/Done", Setting.purchase_inbox_processed_folder
    assert_equal "mx.google.com", Setting.purchase_inbox_authserv_id
  end

  test "can't be enabled without a trusted authentication host while authentication is required" do
    patch settings_purchase_inbox_url, params: { setting: {
      host: "imap.example.com", username: "orders@example.com", password: "x", authserv_id: "", require_sender_auth: "1", enabled: "1"
    } }

    assert_redirected_to settings_purchase_inbox_url
    assert_not Setting.purchase_inbox_enabled
    assert_equal I18n.t("settings.purchase_inboxes.update.incomplete"), flash[:alert]
  end

  test "clearing a required field while the mailbox is on turns it off and says so" do
    Setting.purchase_inbox_enabled = true
    Setting.purchase_inbox_host = "imap.example.com"
    Setting.purchase_inbox_username = "orders@example.com"
    Setting.purchase_inbox_password = "x"
    Setting.purchase_inbox_authserv_id = "mx.google.com"

    patch settings_purchase_inbox_url, params: { setting: { authserv_id: "" } }

    assert_not Setting.purchase_inbox_enabled
    assert_equal I18n.t("settings.purchase_inboxes.update.incomplete"), flash[:alert]
  end

  test "a family admin on an instance with several families can't change it" do
    @admin.update!(role: :admin)
    User.any_instance.stubs(:manages_instance_settings?).returns(false)

    patch settings_purchase_inbox_url, params: { setting: { host: "evil.example.com" } }

    assert_redirected_to settings_profile_path
    assert_nil Setting.purchase_inbox_host
  end

  test "test connection shows what the server answered" do
    PurchaseInbox::Poller.stubs(:test_connection).returns(ok: true, message_count: 3, authserv_ids: [ "mx.google.com" ], error: nil)

    post test_connection_settings_purchase_inbox_url

    assert_redirected_to settings_purchase_inbox_url
    assert_includes flash[:notice], "3"
    assert_includes flash[:notice], "mx.google.com"
  end

  test "test connection shows the error" do
    PurchaseInbox::Poller.stubs(:test_connection).returns(ok: false, message_count: nil, authserv_ids: [], error: "Invalid credentials")

    post test_connection_settings_purchase_inbox_url

    assert_includes flash[:alert], "Invalid credentials"
  end
end
