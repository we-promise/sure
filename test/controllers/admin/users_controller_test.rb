require "test_helper"

class Admin::UsersControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    sign_in users(:sure_support_staff)
  end

  test "index groups users by family sorted by transaction count" do
    family_with_more = users(:family_admin).family
    family_with_fewer = users(:empty).family

    account = Account.create!(family: family_with_more, name: "Test", balance: 0, currency: "USD", accountable: Depository.new)
    3.times { |i| account.entries.create!(name: "Txn #{i}", date: Date.current, amount: 10, currency: "USD", entryable: Transaction.new) }

    get admin_users_url
    assert_response :success

    body = response.body
    more_idx = body.index(family_with_more.name)
    fewer_idx = body.index(family_with_fewer.name)

    assert_not_nil more_idx
    assert_not_nil fewer_idx
    assert_operator more_idx, :<, fewer_idx,
      "Family with more transactions should appear before family with fewer"
  end

  test "index shows subscription status for families" do
    family = users(:family_admin).family
    family.subscription&.destroy
    Subscription.create!(
      family_id: family.id,
      status: :active,
      stripe_id: "cus_test_#{family.id}"
    )

    get admin_users_url
    assert_response :success
    assert_match(/Active/, response.body, "Page should show subscription status for families with active subscriptions")
  end

  test "index shows no subscription label for families without subscription" do
    users(:family_admin).family.subscription&.destroy

    get admin_users_url
    assert_response :success
    assert_match(/No subscription/, response.body, "Page should show 'No subscription' for families without one")
  end

  test "index renders auth type pills for local and sso users" do
    solo_family = Family.create!(name: "SSO Test Family")
    sso_email = "unique-sso-user-#{SecureRandom.hex(4)}@example.com"
    sso_user = User.create!(
      family: solo_family,
      email: sso_email,
      first_name: "SSO",
      last_name: "User",
      skip_password_validation: true,
      role: :member
    )
    OidcIdentity.create!(
      user: sso_user,
      provider: "google",
      uid: "google-12345"
    )

    get admin_users_url
    assert_response :success

    # Locate each user's row and verify auth-type pills are scoped correctly
    doc = Nokogiri::HTML(response.body)
    sso_row = doc.at_css("tr:has(p:contains('#{sso_email}'))")
    assert sso_row, "Expected a table row for SSO user #{sso_email}"
    assert_match(/SSO/, sso_row.text)
    assert_match(/SSO Provider: /, sso_row.text)

    local_email = users(:family_admin).email
    local_row = doc.at_css("tr:has(p:contains('#{local_email}'))")
    assert local_row, "Expected a table row for local user #{local_email}"
    assert_match(/Local/, local_row.text)
  end

  test "index exposes delete and family controls for super admins" do
    Family.create!(name: "Unused Family")

    get admin_users_url
    assert_response :success

    assert_match(/Delete User/, response.body)
    assert_match(/New family\/group name/, response.body)
    assert_match(/Unused families \/ groups/, response.body)
    assert_match(/Delete unused family/, response.body)
  end



  test "update can move a user to an existing family" do
    target = users(:family_member)
    destination_family = Family.create!(name: "New Admin Family")
    destination_family.update!(default_account_sharing: "shared")
    destination_member = User.create!(
      family: destination_family,
      email: "destination-member@example.com",
      first_name: "Destination",
      last_name: "Member",
      password: "password",
      role: :member
    )
    shared_account = Account.create!(family: target.family, owner: users(:family_admin), name: "Shared", balance: 50, currency: "USD", accountable: Depository.new)
    shared_account.share_with!(target, permission: "read_only")

    patch admin_user_url(target), params: {
      user: {
        role: "member",
        family_id: destination_family.id,
        new_family_name: ""
      }
    }

    assert_redirected_to admin_users_url
    target.reload

    assert_equal destination_family, target.family
    assert_equal "member", target.role
    assert_equal 0, AccountShare.where(user: target).count
    assert_equal 0, AccountShare.where(account: shared_account).where(user: target).count
  end

  test "update can create a new family and move the user into it" do
    target = users(:family_member)

    assert_difference("Family.count", 1) do
      patch admin_user_url(target), params: {
        user: {
          role: "admin",
          family_id: "",
          new_family_name: "New Support Group",
          new_family_moniker: "Group"
        }
      }
    end

    assert_redirected_to admin_users_url
    target.reload

    assert_equal "New Support Group", target.family.name
    assert_equal "Group", target.family.moniker
    assert_equal "admin", target.role
  end

  test "update ignores whitespace-only new family name when existing family is selected" do
    target = users(:family_member)
    destination_family = Family.create!(name: "Destination Family")

    assert_no_difference("Family.count") do
      patch admin_user_url(target), params: {
        user: {
          role: "member",
          family_id: destination_family.id,
          new_family_name: "   ",
          new_family_moniker: "Group"
        }
      }
    end

    assert_redirected_to admin_users_url
    target.reload

    assert_equal destination_family, target.family
    assert_equal "member", target.role
  end

  test "update rejects blank new family selection" do
    target = users(:family_member)
    original_family = target.family

    assert_no_difference("Family.count") do
      patch admin_user_url(target), params: {
        user: {
          role: "member",
          family_id: "new",
          new_family_name: "   ",
          new_family_moniker: "Group"
        }
      }
    end

    assert_redirected_to admin_users_url
    assert_equal I18n.t("admin.users.update.family_required"), flash[:alert]
    assert_equal original_family, target.reload.family
  end

  test "update rolls back a new family when transfer validation fails" do
    target = users(:family_member)
    original_family = target.family

    assert_no_difference("Family.count") do
      patch admin_user_url(target), params: {
        user: {
          role: "not-a-real-role",
          family_id: "",
          new_family_name: "Rollback Family",
          new_family_moniker: "Group"
        }
      }
    end

    assert_match(/Role is not included in the list/, flash[:alert])
    target.reload

    assert_equal original_family, target.family
    assert_equal "member", target.role
  end

  test "update shows failure when selected family does not exist" do
    target = users(:family_member)
    missing_family_id = SecureRandom.uuid

    missing_family_id = SecureRandom.uuid while Family.exists?(id: missing_family_id)

    patch admin_user_url(target), params: {
      user: {
        role: "member",
        family_id: missing_family_id,
        new_family_name: ""
      }
    }

    assert_redirected_to admin_users_url
    assert_equal I18n.t("admin.users.update.failure"), flash[:alert]
  end



  test "update allows super admin to change their own family" do
    current_admin = users(:sure_support_staff)
    new_family = Family.create!(name: "Self Move Family")

    patch admin_user_url(current_admin), params: {
      user: {
        role: "super_admin",
        family_id: new_family.id
      }
    }

    assert_redirected_to admin_users_url
    assert_equal new_family, current_admin.reload.family
  end

  test "update prevents demoting the last super admin in the system" do
    User.where(role: :super_admin).where.not(id: users(:sure_support_staff).id).update_all(role: :member)
    current_admin = users(:sure_support_staff)

    patch admin_user_url(current_admin), params: {
      user: {
        role: "member",
        family_id: current_admin.family_id
      }
    }

    assert_redirected_to admin_users_url
    assert_match(/cannot demote the last super admin/i, flash[:alert])
    assert_equal "super_admin", current_admin.reload.role
  end

  test "update can set a new password for a local user" do
    target = users(:family_member)
    assert target.has_local_password?, "Precondition: target must have a local password"

    new_password = "Secure1!pass"
    patch admin_user_url(target), params: {
      user: {
        role: target.role,
        password: new_password
      }
    }

    assert_redirected_to admin_users_url
    assert_equal I18n.t("admin.users.update.success_password"), flash[:notice]
    target.reload
    assert target.authenticate(new_password), "User should authenticate with the new password"
  end

  test "update shows descriptive notification for role change only" do
    target = users(:family_member)

    patch admin_user_url(target), params: {
      user: {
        role: "admin",
        password: ""
      }
    }

    assert_redirected_to admin_users_url
    assert_equal I18n.t("admin.users.update.success_role"), flash[:notice]
  end

  test "update shows descriptive notification for role and password change" do
    target = users(:family_member)
    assert target.has_local_password?, "Precondition: target must have a local password"

    patch admin_user_url(target), params: {
      user: {
        role: "admin",
        password: "Secure1!pass"
      }
    }

    assert_redirected_to admin_users_url
    assert_equal I18n.t("admin.users.update.success_role_and_password"), flash[:notice]
    target.reload
    assert_equal "admin", target.role
    assert target.authenticate("Secure1!pass")
  end

  test "update shows descriptive notification for family change" do
    target = users(:family_member)
    destination_family = Family.create!(name: "Notify Family")

    patch admin_user_url(target), params: {
      user: {
        role: target.role,
        family_id: destination_family.id
      }
    }

    assert_redirected_to admin_users_url
    assert_equal I18n.t("admin.users.update.success_family"), flash[:notice]
  end

  test "update with blank password leaves existing password unchanged" do
    target = users(:family_member)
    old_digest = target.password_digest

    patch admin_user_url(target), params: {
      user: {
        role: target.role,
        password: ""
      }
    }

    assert_redirected_to admin_users_url
    assert_equal old_digest, target.reload.password_digest, "Password digest should not change when blank password is submitted"
  end

  test "update with short password shows too short error" do
    target = users(:family_member)
    old_digest = target.password_digest

    patch admin_user_url(target), params: {
      user: { role: target.role, password: "Aa1!xy" }
    }

    assert_redirected_to admin_users_url
    assert_match(/at least 8 characters/i, flash[:alert])
    assert_equal old_digest, target.reload.password_digest
  end

  test "update with password missing uppercase or lowercase shows case error" do
    target = users(:family_member)
    old_digest = target.password_digest

    patch admin_user_url(target), params: {
      user: { role: target.role, password: "alllower1!" }
    }

    assert_redirected_to admin_users_url
    assert_match(/uppercase and lowercase/i, flash[:alert])
    assert_equal old_digest, target.reload.password_digest
  end

  test "update with password missing number shows number error" do
    target = users(:family_member)
    old_digest = target.password_digest

    patch admin_user_url(target), params: {
      user: { role: target.role, password: "NoNumber!!" }
    }

    assert_redirected_to admin_users_url
    assert_match(/at least one number/i, flash[:alert])
    assert_equal old_digest, target.reload.password_digest
  end

  test "update with password missing special character shows special char error" do
    target = users(:family_member)
    old_digest = target.password_digest

    patch admin_user_url(target), params: {
      user: { role: target.role, password: "NoSpecial1a" }
    }

    assert_redirected_to admin_users_url
    assert_match(/special character/i, flash[:alert])
    assert_equal old_digest, target.reload.password_digest
  end

  test "update with password failing multiple criteria shows all errors" do
    target = users(:family_member)
    old_digest = target.password_digest

    patch admin_user_url(target), params: {
      user: { role: target.role, password: "short" }
    }

    assert_redirected_to admin_users_url
    assert_match(/at least 8 characters/i, flash[:alert])
    assert_match(/uppercase and lowercase/i, flash[:alert])
    assert_match(/at least one number/i, flash[:alert])
    assert_match(/special character/i, flash[:alert])
    assert_equal old_digest, target.reload.password_digest
  end

  test "update ignores password param for SSO-only users" do
    solo_family = Family.create!(name: "SSO Ignore Family")
    sso_user = User.create!(
      family: solo_family,
      email: "sso-ignore-#{SecureRandom.hex(4)}@example.com",
      first_name: "SSO",
      last_name: "Ignore",
      skip_password_validation: true,
      role: :member
    )
    OidcIdentity.create!(user: sso_user, provider: "google", uid: "ignore-#{SecureRandom.hex(4)}")
    assert sso_user.sso_only?, "Precondition: user must be SSO-only"
    assert_nil sso_user.password_digest

    patch admin_user_url(sso_user), params: {
      user: {
        role: sso_user.role,
        password: "attempt_to_set_password"
      }
    }

    assert_redirected_to admin_users_url
    assert_nil sso_user.reload.password_digest, "SSO-only user should not gain a local password"
  end

  test "update blocks simultaneous family and password change" do
    target = users(:family_member)
    assert target.has_local_password?, "Precondition: target must have a local password"
    original_family = target.family
    destination_family = Family.create!(name: "Conflict Family")
    old_digest = target.password_digest

    patch admin_user_url(target), params: {
      user: {
        role: target.role,
        family_id: destination_family.id,
        password: "Secure1!pass"
      }
    }

    assert_redirected_to admin_users_url
    assert_equal I18n.t("admin.users.update.password_and_family_conflict"), flash[:alert]
    target.reload
    assert_equal original_family, target.family, "Family should not change when conflict is detected"
    assert_equal old_digest, target.password_digest, "Password should not change when conflict is detected"
  end

  test "index shows set password field for local users but not for SSO-only users" do
    local_user = users(:family_member)
    assert local_user.has_local_password?, "Precondition: local_user must have a local password"

    solo_family = Family.create!(name: "SSO Only Family")
    sso_user = User.create!(
      family: solo_family,
      email: "sso-only-pwd-test-#{SecureRandom.hex(4)}@example.com",
      first_name: "SSO",
      last_name: "Only",
      skip_password_validation: true,
      role: :member
    )
    OidcIdentity.create!(user: sso_user, provider: "google", uid: "pwd-test-#{SecureRandom.hex(4)}")
    assert sso_user.sso_only?, "Precondition: sso_user must be SSO-only"

    get admin_users_url
    assert_response :success

    assert_match(/Set new password/, response.body, "Should show set password field for local users")
  end

  test "index shows removed SSO identities with a recovery action" do
    block = SsoIdentityBlock.create!(
      provider: "openid_connect",
      uid_digest: SsoIdentityBlock.digest("blocked-subject"),
      identity_label: "removed-user@example.com"
    )

    get admin_users_url

    assert_response :success
    assert_select "form[action=?]", admin_sso_identity_block_path(block)
    assert_match block.identity_label, response.body
  end

  test "super admin permanently removes a user and revokes their credentials" do
    target = users(:family_member)
    target_email = target.email
    removed_identity = target.oidc_identities.first!
    removed_provider = removed_identity.provider
    removed_uid = removed_identity.uid
    target.sessions.create!
    oauth_app = Doorkeeper::Application.create!(
      name: "Removal test",
      redirect_uri: "https://app.example/callback",
      confidential: false
    )
    oauth_token = Doorkeeper::AccessToken.create!(
      application: oauth_app,
      resource_owner_id: target.id,
      scopes: "read_write",
      use_refresh_token: true
    )
    assert target.oidc_identities.exists?
    assert target.api_keys.exists?

    assert_difference -> { SsoAuditLog.by_event("user_removed").count }, 1 do
      assert_enqueued_with(job: UserPurgeJob, args: [ target ]) do
        delete admin_user_url(target), params: { confirmation_email: target_email }
      end
    end

    assert_redirected_to admin_users_path
    target.reload
    assert_not target.active?
    assert_empty target.sessions
    assert_empty target.oidc_identities
    assert_empty target.api_keys
    assert oauth_token.reload.revoked?
    assert SsoIdentityBlock.blocked?(provider: removed_provider, uid: removed_uid)
    identity_block = SsoIdentityBlock.find_by!(provider: removed_provider)
    if SsoIdentityBlock.encryption_ready?
      assert_equal target_email, identity_block.identity_label
    else
      assert_not_equal target_email, identity_block.identity_label
    end
    audit_log = SsoAuditLog.by_event("user_removed").order(:created_at).last
    assert_equal target.id, audit_log.metadata.fetch("target_user_id")
    assert_not audit_log.metadata.key?("target_email")
    assert_equal users(:sure_support_staff).id, audit_log.metadata.fetch("actor_user_id")
  end

  test "super admin cannot remove themselves" do
    me = users(:sure_support_staff)

    assert_no_enqueued_jobs only: UserPurgeJob do
      delete admin_user_url(me)
    end

    assert_redirected_to admin_users_path
    assert User.exists?(me.id)
    assert me.reload.active?
  end

  test "audit failure rolls back user removal" do
    target = users(:family_member)
    target_email = target.email
    SsoAuditLog.expects(:log_user_removed!).raises("audit failure")

    assert_no_enqueued_jobs only: UserPurgeJob do
      assert_raises(RuntimeError, match: /audit failure/) do
        delete admin_user_url(target), params: { confirmation_email: target_email }
      end
    end

    assert target.reload.active?
    assert target.oidc_identities.exists?
  end

  test "inactive super admin cannot use an existing session to remove the last active super admin" do
    target = users(:family_admin)
    target.update!(role: :super_admin)
    User.where(role: :super_admin).where.not(id: target.id).update_all(active: false)

    assert_no_enqueued_jobs only: UserPurgeJob do
      delete admin_user_url(target), params: { confirmation_email: target.email }
    end

    assert_redirected_to new_session_path
    assert User.exists?(target.id)
    assert target.reload.active?
  end

  test "deletion page redirects instead of erroring when targeting yourself" do
    me = users(:sure_support_staff)

    get deletion_admin_user_url(me)

    assert_redirected_to admin_users_path
    assert_match(/cannot remove your own account/i, flash[:alert].to_s)
  end

  test "deletion confirmation requires the target email" do
    target = users(:family_member)

    assert_no_enqueued_jobs only: UserPurgeJob do
      delete admin_user_url(target), params: { confirmation_email: "wrong@example.com" }
    end

    assert_redirected_to admin_users_path
    assert target.reload.active?
  end

  test "deletion page renders a typed email confirmation dialog" do
    target = users(:family_member)

    get deletion_admin_user_url(target)

    assert_response :success
    assert_select "dialog"
    assert_select "input[name=confirmation_email][required]"
    assert_includes response.body, target.email
  end

  test "non super admin cannot remove a user" do
    sign_in users(:family_member)
    target = users(:family_admin)

    assert_no_enqueued_jobs only: UserPurgeJob do
      delete admin_user_url(target)
    end

    assert_redirected_to root_path
    assert User.exists?(target.id)
  end
end
