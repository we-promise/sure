require "test_helper"

class Account::LiquidityTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @today = Date.new(2026, 10, 5)
  end

  test "new accounts take the default of their type and subtype" do
    expectations = {
      [ Depository, "checking" ] => "immediate",
      [ Depository, "savings" ] => "immediate",
      [ Depository, "money_market" ] => "short_term",
      [ Depository, "notice_savings" ] => "short_term",
      [ Depository, "cd" ] => "locked",
      [ Depository, "building_savings" ] => "locked",
      [ Depository, "hsa" ] => "long_term",
      [ Investment, "brokerage" ] => "short_term",
      [ Investment, "401k" ] => "long_term",
      [ Investment, "riester" ] => "long_term",
      [ Investment, "ruerup" ] => "long_term",
      [ Investment, "bav" ] => "long_term",
      [ Investment, "vl" ] => "locked",
      [ Investment, "fd" ] => "locked",
      [ Investment, nil ] => "short_term",
      [ Crypto, "exchange" ] => "short_term",
      [ Property, nil ] => "long_term",
      [ Vehicle, nil ] => "long_term",
      [ OtherAsset, nil ] => "long_term",
      [ CreditCard, nil ] => "immediate",
      [ Loan, "mortgage" ] => "long_term",
      [ Loan, "line_of_credit" ] => "immediate",
      [ OtherLiability, nil ] => "long_term"
    }

    expectations.each do |(klass, subtype), level|
      account = create_account(klass, subtype)
      assert_equal level, account.liquidity, "#{klass.name}/#{subtype.inspect}"
      assert_not account.liquidity_manual?
    end
  end

  test "a subtype change moves an automatic account to the new default" do
    account = create_account(Depository, "checking")

    account.update!(subtype: "cd")

    assert_equal "locked", account.reload.liquidity
  end

  test "a subtype changed directly on the accountable also moves the default" do
    account = create_account(Depository, "checking")

    account.accountable.update!(subtype: "cd")

    assert_equal "locked", account.reload.liquidity
  end

  test "a manual choice is locked and survives subtype changes" do
    account = create_account(Depository, "savings")

    account.update!(liquidity_choice: "locked", available_on: @today + 30)
    account.update!(subtype: "checking")
    account.accountable.update!(subtype: "money_market")

    account.reload
    assert_equal "locked", account.liquidity
    assert account.liquidity_manual?
    assert_equal "locked", account.liquidity_choice_for_form
  end

  test "a manual choice equal to the old value still wins over a subtype change in the same save" do
    account = create_account(Depository, "checking")

    account.update!(liquidity_choice: "immediate", subtype: "cd")

    assert_equal "immediate", account.reload.liquidity
    assert account.liquidity_manual?
  end

  test "choosing automatic unlocks and restores the subtype default" do
    account = create_account(Depository, "cd")
    account.update!(liquidity_choice: "immediate")

    account.update!(liquidity_choice: Account::Liquidity::AUTOMATIC)

    account.reload
    assert_equal "locked", account.liquidity
    assert_not account.liquidity_manual?
    assert_equal Account::Liquidity::AUTOMATIC, account.liquidity_choice_for_form
  end

  test "release fields are cleared when the account is not locked" do
    account = create_account(Depository, "cd")
    account.update!(available_on: @today + 10, auto_renew: true, renewal_term_months: 12)

    account.update!(liquidity_choice: "short_term")

    account.reload
    assert_nil account.available_on
    assert_not account.auto_renew?
    assert_nil account.renewal_term_months
  end

  test "an unknown choice is rejected" do
    account = create_account(Depository, "checking")

    assert_not account.update(liquidity_choice: "whenever")
    assert account.errors.of_kind?(:liquidity, :inclusion)
  end

  test "auto renewal needs a term" do
    account = create_account(Depository, "cd")

    assert_not account.update(auto_renew: true, renewal_term_months: nil)
    assert account.errors.of_kind?(:renewal_term_months, :blank)
  end

  test "a locked account becomes available on its release date" do
    account = create_account(Depository, "cd")
    account.update!(available_on: @today + 10)

    assert_not account.available_on?(@today + 9)
    assert account.available_on?(@today + 10)
    assert_equal "locked", account.effective_liquidity(@today + 9)
    assert_equal "immediate", account.effective_liquidity(@today + 10)
    assert_equal 10, account.days_until_available(@today)
  end

  test "a locked account without a date stays locked" do
    account = create_account(Depository, "cd")

    assert_not account.available_on?(@today + 1000)
    assert_nil account.next_release_date(@today)
  end

  test "an auto renewing deposit rolls its release date forward and never releases" do
    account = create_account(Depository, "cd")
    account.update!(available_on: Date.new(2025, 3, 31), auto_renew: true, renewal_term_months: 6)

    assert_equal Date.new(2026, 9, 30), account.next_release_date(Date.new(2026, 9, 30))
    assert_equal Date.new(2027, 3, 31), account.next_release_date(@today), "month-end dates do not slip"
    assert_not account.available_on?(@today)
  end

  test "a provider changing the subtype away from locked clears the release fields" do
    account = create_account(Depository, "cd")
    account.update!(available_on: @today + 10, auto_renew: true, renewal_term_months: 12)

    account.accountable.update!(subtype: "savings")

    account.reload
    assert_equal "immediate", account.liquidity
    assert_nil account.available_on
    assert_not account.auto_renew?
    assert_nil account.renewal_term_months
  end

  test "details separate budget transactions from budget cash" do
    account = create_account(Depository, "money_market")
    rows = Account::RuleDetails.new(account, date: @today).rows.index_by(&:key)

    assert_equal "short_term", rows[:liquidity].value
    assert_equal :subtype, rows[:liquidity].source
    assert rows[:counts_in_budget].value
    assert_not rows[:counts_as_budget_cash].value
    assert_nil rows[:release]

    account.update!(liquidity_choice: "immediate")
    rows = Account::RuleDetails.new(account, date: @today).rows.index_by(&:key)

    assert_equal :user, rows[:liquidity].source
    assert rows[:counts_as_budget_cash].value
  end

  test "scopes split assets by availability on a date" do
    checking = create_account(Depository, "checking")
    brokerage = create_account(Investment, "brokerage")
    cd = create_account(Depository, "cd")
    cd.update!(available_on: @today + 10)
    pension = create_account(Investment, "401k")
    card = create_account(CreditCard, nil)
    mortgage = create_account(Loan, "mortgage")
    ids = [ checking, brokerage, cd, pension, card, mortgage ].map(&:id)
    accounts = Account.where(id: ids)

    assert_equal [ checking, brokerage ].map(&:id).sort, accounts.available_assets_on(@today).pluck(:id).sort
    assert_equal [ checking, brokerage, cd ].map(&:id).sort, accounts.available_assets_on(@today + 10).pluck(:id).sort
    assert_equal [ checking ].map(&:id), accounts.immediate_assets_on(@today).pluck(:id)
    assert_equal [ checking, cd ].map(&:id).sort, accounts.immediate_assets_on(@today + 10).pluck(:id).sort
    assert_equal [ cd, pension ].map(&:id).sort, accounts.bound_assets_on(@today).pluck(:id).sort
    assert_equal [ pension ].map(&:id), accounts.bound_assets_on(@today + 10).pluck(:id)
    assert_equal [ card ].map(&:id), accounts.short_term_liabilities.pluck(:id)
  end

  test "today is evaluated in the family's time zone" do
    @family.update!(timezone: "Pacific/Auckland")

    travel_to Time.utc(2026, 10, 4, 12, 0, 0) do
      assert_equal Date.new(2026, 10, 5), Account.liquidity_today_for(@family)
    end
  end

  test "an invalid family time zone falls back to the app zone" do
    @family.update_column(:timezone, "Mars/Olympus")

    assert_equal Date.current, Account.liquidity_today_for(@family)
  end

  test "rules show where tax treatment and budget inclusion come from" do
    rules = Investment.rules_for("401k")

    assert_equal "long_term", rules.liquidity
    assert_equal :tax_deferred, rules.tax_treatment
    assert_not rules.counts_in_budget?
    assert Depository.rules_for("cd").release_date?
    assert Depository.rules_for("checking").counts_in_budget?
    assert_not Depository.rules_for("hsa").counts_in_budget?
  end

  private
    def create_account(klass, subtype)
      @family.accounts.create!(
        name: "#{klass.name} #{subtype}",
        balance: 1000,
        currency: "USD",
        accountable: klass.new(subtype: subtype)
      )
    end
end
