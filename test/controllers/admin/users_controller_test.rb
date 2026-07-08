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

  test "destroy deactivates the target user and revokes their sessions" do
    target = users(:family_member)
    target.sessions.create!(user_agent: "test", ip_address: "127.0.0.1")
    assert target.active
    assert target.sessions.any?

    delete admin_user_url(target)

    assert_redirected_to admin_users_url
    assert_not target.reload.active
    assert_empty target.sessions.reload
  end

  test "cannot delete own account" do
    me = users(:sure_support_staff)

    delete admin_user_url(me)

    assert_redirected_to admin_users_url
    assert me.reload.active
  end

  test "non super admin cannot delete users" do
    sign_in users(:family_admin)
    target = users(:family_member)

    delete admin_user_url(target)

    assert_redirected_to root_url
    assert target.reload.active
  end
end
