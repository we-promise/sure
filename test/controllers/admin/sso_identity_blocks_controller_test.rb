require "test_helper"

class Admin::SsoIdentityBlocksControllerTest < ActionDispatch::IntegrationTest
  setup do
    @block = SsoIdentityBlock.create!(
      provider: "openid_connect",
      uid_digest: SsoIdentityBlock.digest("removed-subject"),
      identity_label: "removed-user@example.com"
    )
  end

  test "super admin can allow a removed SSO identity again" do
    sign_in users(:sure_support_staff)

    assert_difference -> { SsoIdentityBlock.count }, -1 do
      assert_difference -> { SsoAuditLog.by_event("identity_unblocked").count }, 1 do
        delete admin_sso_identity_block_url(@block)
      end
    end

    assert_redirected_to admin_users_path

    audit_log = SsoAuditLog.by_event("identity_unblocked").last
    assert_equal users(:sure_support_staff).id, audit_log.metadata["actor_user_id"]
    assert_equal @block.id, audit_log.metadata["identity_block_id"]
    assert_equal @block.provider, audit_log.provider
  end

  test "regular user cannot allow a removed SSO identity again" do
    sign_in users(:family_member)

    assert_no_difference -> { SsoIdentityBlock.count } do
      assert_no_difference -> { SsoAuditLog.by_event("identity_unblocked").count } do
        delete admin_sso_identity_block_url(@block)
      end
    end

    assert_redirected_to root_path
  end
end
