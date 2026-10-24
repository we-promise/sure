require "test_helper"

class Account::MutationAccessTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_member)
    @account = accounts(:depository)
    @share = @account.account_shares.find_by!(user: @user)
  end

  test "locks and returns accounts when the current permission satisfies the requested level" do
    result = Account.transaction do
      Account::MutationAccess.lock!(accounts: [ @account ], user: @user, level: Account::MutationAccess::WRITE)
    end

    assert_equal @account.id, result.fetch(@account.id.to_s).id
  end

  test "denies a revoked or downgraded write permission at the final boundary" do
    @share.update!(permission: "read_write")

    assert_raises Account::MutationAccess::Denied do
      Account.transaction do
        Account::MutationAccess.lock!(accounts: [ @account ], user: @user, level: Account::MutationAccess::WRITE)
      end
    end

    assert Account.transaction { Account::MutationAccess.lock!(accounts: [ @account ], user: @user, level: Account::MutationAccess::ANNOTATE) }
  end

  test "returns locked accounts in deterministic id order" do
    second = @user.family.accounts.create!(owner: @user, name: "Second locking account", accountable: Depository.new, balance: 0, currency: "USD")

    result = Account.transaction do
      Account::MutationAccess.lock!(accounts: [ second, @account ], user: @user, level: Account::MutationAccess::READ)
    end

    assert_equal [ @account.id, second.id ].sort.map(&:to_s), result.keys
  end
end
