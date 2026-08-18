require "test_helper"

class CurrentTest < ActiveSupport::TestCase
  test "family returns user family" do
    user = users(:family_admin)
    Current.session = user.sessions.create!
    assert_equal user.family, Current.family
  end

  test "accessible_accounts cache resets with Current.reset" do
    admin = users(:family_admin)
    member = users(:family_member)

    Current.session = admin.sessions.create!
    admin_account_ids = Current.accessible_accounts.pluck(:id).sort

    Current.reset

    Current.session = member.sessions.create!
    member_account_ids = Current.accessible_accounts.pluck(:id).sort

    assert admin_account_ids.size > member_account_ids.size
    assert_equal member_account_ids, member.accessible_accounts.pluck(:id).sort
  end

  test "finance_accounts cache resets with Current.reset" do
    admin = users(:family_admin)
    member = users(:family_member)

    Current.session = admin.sessions.create!
    admin_account_ids = Current.finance_accounts.pluck(:id).sort

    Current.reset

    Current.session = member.sessions.create!
    member_account_ids = Current.finance_accounts.pluck(:id).sort

    assert admin_account_ids.size > member_account_ids.size
    assert_equal member_account_ids, member.finance_accounts.pluck(:id).sort
  end
end
