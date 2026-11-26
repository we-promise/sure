require "test_helper"

class CurrentTest < ActiveSupport::TestCase
  test "family returns user family" do
    user = users(:family_admin)
    Current.session = user.sessions.create!
    assert_equal user.family, Current.family
  end

  test "account_share_version moves when a share other than the latest one is removed" do
    user = users(:family_member)
    Current.session = user.sessions.create!
    older_share = account_shares(:depository_shared_with_member)
    older_share.update_columns(updated_at: 1.day.ago)

    before = Current.account_share_version
    assert_match(/\A2-\d+(\.\d+)?\z/, before)

    older_share.destroy!

    assert_not_equal before, Current.account_share_version
  end

  test "account_share_version moves when a share is updated" do
    user = users(:family_member)
    Current.session = user.sessions.create!
    share = account_shares(:credit_card_shared_with_member)

    before = Current.account_share_version
    travel 1.second do
      share.touch
    end

    assert_not_equal before, Current.account_share_version
  end

  test "account_share_version is constant without a user" do
    assert_equal "0-", Current.account_share_version
  end
end
