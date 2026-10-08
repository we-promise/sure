require "test_helper"

class Loan::CollateralPositionTest < ActiveSupport::TestCase
  setup do
    @admin = users(:family_admin)
    @member = users(:family_member)
    @loan_account = accounts(:loan)
    @property = accounts(:property)
    @property.update_columns(balance: 550_000)
    @loan_account.update_columns(balance: 500_000)
    @loan_account.loan.update!(collateral_account: @property)
  end

  test "equity is the collateral's value less the debt secured on it" do
    position = Loan::CollateralPosition.for_collateral(@property, viewer: @admin)

    assert_equal Money.new(550_000, "USD"), position.value
    assert_equal Money.new(500_000, "USD"), position.debt
    assert_equal Money.new(50_000, "USD"), position.equity
    assert position.complete?
  end

  test "every loan on the asset counts, so equity is not measured against one of them" do
    second = secure_another_loan(balance: 100_000)

    from_collateral = Loan::CollateralPosition.for_collateral(@property, viewer: @admin)
    from_first_loan = Loan::CollateralPosition.for_loan(@loan_account.loan, viewer: @admin)
    from_second_loan = Loan::CollateralPosition.for_loan(second.loan, viewer: @admin)

    assert_equal Money.new(600_000, "USD"), from_collateral.debt
    assert_equal Money.new(-50_000, "USD"), from_collateral.equity
    assert_equal from_collateral.equity, from_first_loan.equity
    assert_equal from_collateral.equity, from_second_loan.equity
    assert_equal [ @loan_account.id, second.id ].sort, from_collateral.loan_accounts.map(&:id).sort
  end

  test "equity is withheld when the viewer cannot see every loan secured on the asset" do
    second = secure_another_loan(balance: 100_000)
    share_with_member(@property, @loan_account)

    position = Loan::CollateralPosition.for_collateral(@property, viewer: @member)

    assert_not position.complete?
    assert_nil position.equity
    assert_nil position.debt
    assert_equal Money.new(550_000, "USD"), position.value
    assert_equal [ @loan_account.id ], position.loan_accounts.map(&:id)
    assert_not_includes position.loan_accounts.map(&:id), second.id
  end

  test "the loan side returns nothing when the viewer cannot see the collateral" do
    share_with_member(@loan_account)

    assert_nil Loan::CollateralPosition.for_loan(@loan_account.loan, viewer: @member)
  end

  test "the loan side is shown once the viewer can see both" do
    share_with_member(@property, @loan_account)

    position = Loan::CollateralPosition.for_loan(@loan_account.loan, viewer: @member)

    assert_equal Money.new(50_000, "USD"), position.equity
  end

  test "a loan that is switched off no longer counts as debt" do
    second = secure_another_loan(balance: 100_000)
    second.update_columns(status: "disabled")

    position = Loan::CollateralPosition.for_collateral(@property, viewer: @admin)

    assert_equal Money.new(500_000, "USD"), position.debt
    assert_equal Money.new(50_000, "USD"), position.equity
  end

  test "equity is withheld rather than summed across currencies" do
    second = secure_another_loan(balance: 100_000)
    second.update_columns(currency: "EUR")

    position = Loan::CollateralPosition.for_collateral(@property, viewer: @admin)

    assert_not position.complete?
    assert_nil position.equity
  end

  # A switched-off loan is not counted as debt, so its own page would otherwise
  # show the asset's full value as equity, against nothing.
  test "a loan that is switched off shows no position of its own" do
    @loan_account.update_columns(status: "disabled")

    assert_nil Loan::CollateralPosition.for_loan(@loan_account.loan, viewer: @admin)
    assert_nil Loan::CollateralPosition.for_collateral(@property, viewer: @admin)
  end

  test "an asset with no valuation yet has no position" do
    @property.update_columns(balance: nil)

    assert_nil Loan::CollateralPosition.for_collateral(@property, viewer: @admin)
    assert_nil Loan::CollateralPosition.for_loan(@loan_account.loan, viewer: @admin)
  end

  test "equity is withheld while a linked loan has no balance" do
    second = secure_another_loan(balance: 100_000)
    second.update_columns(balance: nil)

    position = Loan::CollateralPosition.for_collateral(@property, viewer: @admin)

    assert_not position.complete?
    assert_nil position.equity
    assert_equal Money.new(550_000, "USD"), position.value
  end

  test "nothing to show for an asset that secures no loan, or a loan with no asset" do
    assert_nil Loan::CollateralPosition.for_collateral(accounts(:vehicle), viewer: @admin)

    @loan_account.loan.update!(collateral_account: nil)
    assert_nil Loan::CollateralPosition.for_loan(@loan_account.loan, viewer: @admin)
    assert_nil Loan::CollateralPosition.for_collateral(@property, viewer: @admin)
  end

  private
    def secure_another_loan(balance:)
      account = @loan_account.family.accounts.create!(
        name: "Second mortgage", currency: "USD", balance: balance, owner: @admin, accountable: Loan.new
      )
      account.loan.update!(collateral_account: @property)
      account
    end

    def share_with_member(*accounts)
      accounts.each { |account| account.share_with!(@member, permission: "read_only") }
    end
end
