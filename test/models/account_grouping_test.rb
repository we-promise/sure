require "test_helper"

class AccountGroupingTest < ActiveSupport::TestCase
  setup do
    @family = families(:empty)
    @user = users(:empty)
  end

  test "groups by account type in the usual type order" do
    loan = create_account(accountable: Loan.new)
    cash = create_account(accountable: Depository.new)

    groups = AccountGrouping.new("account_type", user: @user).group([ loan, cash ])

    assert_equal [ Depository.display_name, Loan.display_name ], groups.map(&:name)
  end

  test "labels a merged group the same whatever the account order" do
    upper = create_account(institution_name: "ING")
    lower = create_account(institution_name: "ing")
    grouping = AccountGrouping.new("institution", user: @user)

    assert_equal [ "ING" ], grouping.group([ upper, lower ]).map(&:name)
    assert_equal [ "ING" ], grouping.group([ lower, upper ]).map(&:name)
  end

  test "rejects unknown dimensions" do
    assert_raises(ArgumentError) { AccountGrouping.new("name", user: @user) }
  end

  test "groups by custom group, case-insensitively, with unset values last" do
    a = create_account(custom_group: "Vacation")
    b = create_account(custom_group: " vacation ")
    c = create_account(custom_group: "Business")
    d = create_account

    groups = AccountGrouping.new("custom_group", user: @user).group([ a, b, c, d ])

    assert_equal [ "Business", "Vacation", I18n.t("account_grouping.none") ], groups.map(&:name)
    assert_equal [ [ c ], [ a, b ], [ d ] ], groups.map(&:accounts)
  end

  test "keeps a group literally named None apart from unset values" do
    named = create_account(custom_group: "None")
    unset = create_account

    groups = AccountGrouping.new("custom_group", user: @user).group([ named, unset ])

    assert_equal [ [ named ], [ unset ] ], groups.map(&:accounts)
    assert_equal [ "None", I18n.t("account_grouping.none") ], groups.map(&:name)
    assert_nil groups.last.key
  end

  test "groups by connection with manual accounts in their own group" do
    groups = AccountGrouping.new("connection", user: users(:family_admin))
      .group([ accounts(:depository), accounts(:connected) ])

    assert_equal [ I18n.t("account_grouping.connections.manual"), "Plaid" ], groups.map(&:name)
  end

  test "groups by ownership from the viewer's perspective" do
    mine = create_account(owner: @user)
    theirs = create_account(owner: users(:sso_only))

    groups = AccountGrouping.new("ownership", user: @user).group([ theirs, mine ])

    assert_equal [ [ mine ], [ theirs ] ], groups.map(&:accounts)
    assert_equal I18n.t("account_grouping.ownership.mine"), groups.first.name
  end

  test "custom group is squished and limited in length" do
    account = create_account(custom_group: "  Kids   fund ")
    assert_equal "Kids fund", account.custom_group

    account.custom_group = "x" * (AccountGrouping::CUSTOM_GROUP_MAX_LENGTH + 1)
    assert_not account.valid?

    account.update!(custom_group: "   ")
    assert_nil account.custom_group
  end

  private
    def create_account(**attributes)
      @family.accounts.create!(name: "Test", balance: 100, currency: "USD", **{ accountable: Depository.new }.merge(attributes))
    end
end
