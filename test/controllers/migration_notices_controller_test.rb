require "test_helper"

class MigrationNoticesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    sign_in @user
    @family = @user.family
  end

  test "destroy adds the key to the family's dismissed list and redirects back" do
    refute @family.dismissed_migration_notice?(:plaid_oauth_redirect_uri)

    delete migration_notice_path(key: "plaid_oauth_redirect_uri"),
           headers: { "Referer" => settings_providers_url }

    assert_response :redirect
    assert @family.reload.dismissed_migration_notice?(:plaid_oauth_redirect_uri)
  end

  test "destroy is idempotent on a key already dismissed" do
    @family.dismiss_migration_notice!(:plaid_oauth_redirect_uri)

    assert_no_difference -> { @family.reload.dismissed_migration_notices.size } do
      delete migration_notice_path(key: "plaid_oauth_redirect_uri"),
             headers: { "Referer" => settings_providers_url }
    end
    assert_response :redirect
  end

  test "destroy requires admin" do
    sign_in users(:family_member) # non-admin
    delete migration_notice_path(key: "plaid_oauth_redirect_uri")
    assert_response :redirect # require_admin! redirects
    refute @family.reload.dismissed_migration_notice?(:plaid_oauth_redirect_uri)
  end
end
