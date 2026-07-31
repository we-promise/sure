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

  test "update can move a user to an existing family" do
    target = users(:family_member)
    destination_family = Family.create!(name: "New Admin Family")
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
    assert_equal 0, AccountShare.where(user: target).count
    assert_equal 0, AccountShare.where(account: owned_account).count
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

  test "destroy purges a user" do
    target = users(:family_member)
    owned_account = Account.create!(family: target.family, owner: target, name: "Savings", balance: 25, currency: "USD", accountable: Depository.new)
    replacement_owner = users(:family_admin)

    assert_difference("User.count", -1) do
      delete admin_user_url(target)
    end

    assert_redirected_to admin_users_url
    assert_equal replacement_owner, owned_account.reload.owner
  end
end
