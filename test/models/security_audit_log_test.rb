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
    api_key = ApiKey.create!(user: @user, name: "Test Key", display_key: "test_key_#{SecureRandom.hex(8)}", scopes: [ "read" ]) # pipelock:ignore

    log = SecurityAuditLog.log_api_key_created!(user: @user, api_key: api_key, request: @request)

    assert_equal "api_key_created", log.event_type
    assert_equal api_key.id, log.metadata["api_key_id"]
    assert_equal "Test Key", log.metadata["name"]
    assert_equal @user.email, log.metadata["user_email"]
    assert_equal "203.0.113.5", log.ip_address
  end

  test "log_password_changed! does not include the password anywhere" do
    log = SecurityAuditLog.log_password_changed!(user: @user, request: @request)

    assert_equal "password_changed", log.event_type
    assert_equal @user.email, log.metadata["user_email"]
    assert_not_includes log.metadata.to_s, "password"
  end

  test "log_password_changed! records the actor when someone else changed the password" do
    admin = users(:family_admin)
    other_user = users(:family_member)

    log = SecurityAuditLog.log_password_changed!(user: other_user, request: @request, actor: admin)

    assert_equal admin.id, log.metadata["actor_user_id"]
  end

  test "log_password_changed! does not record an actor for self-service changes" do
    log = SecurityAuditLog.log_password_changed!(user: @user, request: @request, actor: @user)

    assert_nil log.metadata["actor_user_id"]
  end

  test "survives its user being deleted, preserving the user's email in metadata" do
    disposable_user = User.create!(
      email: "disposable-audit-test@example.com",
      password: "somesecurepassword12345",
      first_name: "Disposable",
      last_name: "User",
      family: families(:dylan_family)
    )
    log = SecurityAuditLog.log_mfa_enabled!(user: disposable_user, request: @request)

    disposable_user.destroy!

    log.reload
    assert_nil log.user_id
    assert_equal "disposable-audit-test@example.com", log.metadata["user_email"]
  end
end
