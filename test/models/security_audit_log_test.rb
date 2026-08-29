require "test_helper"

class SecurityAuditLogTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @request = ActionDispatch::TestRequest.create
    @request.remote_addr = "203.0.113.5"
    @request.user_agent = "TestAgent/1.0"
  end

  test "rejects an event_type outside the allowlist" do
    log = SecurityAuditLog.new(user: @user, event_type: "not_a_real_event")
    assert_not log.valid?
    assert_includes log.errors[:event_type], "is not included in the list"
  end

  test "log_api_key_created! records the api key id, name, and scopes" do
    api_key = ApiKey.create!(user: @user, name: "Test Key", display_key: "test_key_abc", scopes: [ "read" ])

    log = SecurityAuditLog.log_api_key_created!(user: @user, api_key: api_key, request: @request)

    assert_equal "api_key_created", log.event_type
    assert_equal api_key.id, log.metadata["api_key_id"]
    assert_equal "Test Key", log.metadata["name"]
    assert_equal "203.0.113.5", log.ip_address
  end

  test "log_password_changed! does not include the password anywhere" do
    log = SecurityAuditLog.log_password_changed!(user: @user, request: @request)

    assert_equal "password_changed", log.event_type
    assert_empty log.metadata
  end

  test "survives its user being deleted" do
    disposable_user = User.create!(
      email: "disposable-audit-test@example.com",
      password: "somesecurepassword12345",
      first_name: "Disposable",
      last_name: "User",
      family: families(:dylan_family)
    )
    log = SecurityAuditLog.log_mfa_enabled!(user: disposable_user, request: @request)

    disposable_user.destroy!

    assert_nil log.reload.user_id
  end
end
