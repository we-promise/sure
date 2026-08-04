require "test_helper"

class Admin::UsersControllerTest < ActionDispatch::IntegrationTest
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

  test "index exposes delete and family controls for super admins" do
    Family.create!(name: "Unused Family")

    get admin_users_url
    assert_response :success

    assert_match(/Delete user/, response.body)
    assert_match(/New family\/group name/, response.body)
    assert_match(/Are you sure you want to delete this user\?/, response.body)
    assert_match(/Unused families \/ groups/, response.body)
    assert_match(/Delete unused family/, response.body)
  end

  test "index shows stronger delete warning for last user in family" do
    solo_family = Family.create!(name: "Solo Family")
    User.create!(
      family: solo_family,
      email: "solo-family-user@example.com",
      first_name: "Solo",
      last_name: "User",
      password: "password",
      role: :member
    )

    get admin_users_url
    assert_response :success

    assert_match(/delete this user\? This is the last user in their family\/group, so deleting them will also delete the entire family\/group and all associated data/i, response.body)
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
    owned_account = Account.create!(family: target.family, owner: target, name: "Checking", balance: 100, currency: "USD", accountable: Depository.new)
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
    assert_equal destination_family.id, owned_account.reload.family_id
    assert_includes Account.accessible_by(destination_member).pluck(:id), owned_account.id
    assert_equal 0, AccountShare.where(user: target).count
    assert_equal 1, AccountShare.where(account: owned_account).count
    assert AccountShare.exists?(account: owned_account, user: destination_member)
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

  test "destroy purges a user" do
    target = users(:family_member)
    owned_account = Account.create!(family: target.family, owner: target, name: "Savings", balance: 25, currency: "USD", accountable: Depository.new)
    replacement_owner = users(:family_admin)

    assert_difference("User.count", -1) do
      delete admin_user_url(target)
    end

    assert_redirected_to admin_users_url
    assert_equal I18n.t("admin.users.destroy.destroy_success"), flash[:notice]
    assert_equal replacement_owner, owned_account.reload.owner
  end

  test "destroy shows failure when purge does not delete user" do
    target = users(:family_member)
    User.any_instance.stubs(:purge).returns(false)

    assert_no_difference("User.count") do
      delete admin_user_url(target)
    end

    assert_redirected_to admin_users_url
    assert_equal I18n.t("admin.users.destroy.destroy_failure"), flash[:alert]
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
end
