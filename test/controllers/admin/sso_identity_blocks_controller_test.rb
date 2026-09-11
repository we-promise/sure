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
    assert_equal "The SSO identity can sign in or create an account again.", flash[:notice]

    audit_log = SsoAuditLog.by_event("identity_unblocked").last
    assert_equal users(:sure_support_staff).id, audit_log.metadata["actor_user_id"]
    assert_equal @block.id, audit_log.metadata["identity_block_id"]
    assert_equal @block.provider, audit_log.provider
  end

  test "super admin sees the identity unblocked notice in German" do
    user = users(:sure_support_staff)
    user.update!(locale: "de")
    sign_in user

    delete admin_sso_identity_block_url(@block)

    assert_redirected_to admin_users_path
    assert_equal "Die SSO-Identität kann wieder für die Anmeldung oder Kontoerstellung verwendet werden.", flash[:notice]
    assert_equal "Die SSO-Identität kann wieder für die Anmeldung oder Kontoerstellung verwendet werden.",
                 I18n.t("admin.sso_identity_blocks.destroy.success", locale: :de, fallback: false)
  end

  test "super admin sees the removed identity recovery section in German" do
    user = users(:sure_support_staff)
    user.update!(locale: "de")
    sign_in user

    get admin_users_url

    assert_response :success
    assert_includes response.body, "Entfernte SSO-Identitäten"
    assert_includes response.body, "Mit diesen Identitäten kann kein Konto erstellt oder erneut verknüpft werden. Lass eine Identität nur dann wieder zu, wenn sie versehentlich entfernt wurde."
    assert_includes response.body, "Wieder zulassen"
    assert_includes response.body,
                    "Möchtest du die SSO-Identität #{@block.identity_label} wieder für die Anmeldung oder Kontoerstellung zulassen?"
    refute_includes response.body, "Removed SSO identities"

    %w[title description allow_again confirm].each do |key|
      assert I18n.exists?("admin.users.index.removed_sso_identities.#{key}", :de, fallback: false)
    end
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
