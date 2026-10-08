require "test_helper"

class Loan::CollateralAccountTest < ActiveSupport::TestCase
  setup do
    @loan = accounts(:loan).loan
    @property = accounts(:property)
    @vehicle = accounts(:vehicle)
  end

  test "the candidate list works out the loan's viewers once, not once per candidate" do
    family = @loan.account.family
    candidates = Account.where(family: family, accountable_type: %w[Property Vehicle]).count
    assert_operator candidates, :>, 1, "precondition: more than one candidate to judge"

    Loan.any_instance.expects(:collateral_viewers).once.returns(@loan.account.family.users.to_a)

    Loan.collateral_candidates_for(@loan, viewer: users(:family_admin))
  end

  test "a loan can be secured by a property or a vehicle" do
    assert_nil @loan.collateral_account_id

    @loan.update!(collateral_account: @property)
    assert_equal @property, @loan.reload.collateral_account

    @loan.update!(collateral_account: @vehicle)
    assert_equal @vehicle, @loan.reload.collateral_account
  end

  test "rejects an account in another family" do
    foreign = families(:empty).accounts.create!(name: "Not ours", currency: "USD", balance: 1, accountable: Property.new)

    @loan.collateral_account = foreign

    assert_not @loan.valid?
    assert_equal [ "must belong to the same family as the loan" ], @loan.errors[:collateral_account]
  end

  test "rejects another loan" do
    other_loan = @loan.account.family.accounts.create!(name: "Other loan", currency: "USD", balance: 1, accountable: Loan.new)

    @loan.collateral_account = other_loan

    assert_not @loan.valid?
    assert_equal [ "must be a property or vehicle" ], @loan.errors[:collateral_account]
  end

  test "rejects the loan's own account" do
    @loan.collateral_account = @loan.account

    assert_not @loan.valid?
    assert_equal [ "must be a property or vehicle" ], @loan.errors[:collateral_account]
  end

  # `loan.account` used to be nil while a new loan validated, which skipped the
  # family, currency and visibility checks on exactly the path a forged id takes.
  test "a loan being created is judged against the account it is created on" do
    family = @loan.account.family
    foreign = families(:empty).accounts.create!(name: "Not ours", currency: "USD", balance: 1, accountable: Property.new)

    error = assert_raises(ActiveRecord::RecordInvalid) do
      create_loan_on(family, collateral: foreign)
    end

    assert_match "must belong to the same family as the loan", error.message
    assert_no_difference -> { family.accounts.count } do
      assert_raises(ActiveRecord::RecordInvalid) { create_loan_on(family, collateral: foreign) }
    end
  end

  test "a loan can be created already secured by an asset of its own family" do
    family = @loan.account.family
    @property.auto_share_with_family!

    assert_difference -> { family.accounts.count }, 1 do
      created = create_loan_on(family, collateral: @property)

      assert_equal @property.id, created.loan.collateral_account_id
    end
  end

  # A new account in a family that shares by default is visible to everyone in it
  # the moment it exists, but its shares are written after validation. Judged
  # against its owner alone, a private property would pass and then be linked from
  # a loan the whole family can see.
  test "a new loan the family will share cannot be secured by a private asset" do
    family = @loan.account.family
    assert family.share_all_by_default?, "precondition"
    assert_not_equal [], family.users.where.not(id: @property.owner_id).to_a, "precondition"
    @property.account_shares.destroy_all

    error = assert_raises(ActiveRecord::RecordInvalid) { create_loan_on(family, collateral: @property) }

    assert_match "must be visible to every loan viewer", error.message
  end

  test "a new loan in a family that does not share by default only needs its owner to see the asset" do
    family = @loan.account.family
    family.update!(default_account_sharing: "private")
    @property.account_shares.destroy_all

    assert_nothing_raised { create_loan_on(family, collateral: @property) }
  end

  test "an id that is not an account is a validation error, not a foreign key exception" do
    @loan.collateral_account_id = SecureRandom.uuid

    assert_not @loan.valid?
    assert_equal [ "does not exist" ], @loan.errors[:collateral_account]
    assert_no_changes -> { @loan.reload.collateral_account_id } do
      assert_not @loan.update(collateral_account_id: SecureRandom.uuid)
    end
  end

  test "an unknown id on a loan being created is refused too" do
    family = @loan.account.family

    error = assert_raises(ActiveRecord::RecordInvalid) do
      family.accounts.create_and_sync(
        { name: "New loan", balance: 1_000, currency: "USD", owner: users(:family_admin),
          accountable_type: "Loan", accountable_attributes: { collateral_account_id: SecureRandom.uuid } }
      )
    end

    assert_match "does not exist", error.message
  end

  test "rejects any other kind of account" do
    @loan.collateral_account = accounts(:depository)

    assert_not @loan.valid?
    assert_equal [ "must be a property or vehicle" ], @loan.errors[:collateral_account]
  end

  test "rejects an account in a different currency" do
    euro = @loan.account.family.accounts.create!(name: "Flat in Lisbon", currency: "EUR", balance: 1, accountable: Property.new)

    @loan.collateral_account = euro

    assert_not @loan.valid?
    assert_equal [ "must use the same currency as the loan" ], @loan.errors[:collateral_account]
  end

  test "requires every loan viewer to see the collateral" do
    @loan.account.share_with!(users(:family_member), permission: "read_only")
    @loan.collateral_account = @property

    assert_not @loan.valid?
    assert_match "must be visible to every loan viewer", @loan.errors[:collateral_account].join

    @property.share_with!(users(:family_member), permission: "read_only")
    @loan.collateral_account = @property

    assert @loan.valid?
  end

  test "clearing the link is always valid" do
    @loan.update!(collateral_account: @property)

    @loan.update!(collateral_account: nil)

    assert_nil @loan.reload.collateral_account_id
  end

  # The form resubmits the id it already holds on every edit. Validating on every
  # save would turn an asset that later changed currency into a loan nobody can
  # edit; only a change to the link is judged.
  test "saving other fields keeps a link that has since become ineligible" do
    @loan.update!(collateral_account: @property)
    @property.update_columns(currency: "EUR")

    loan = Loan.find(@loan.id)

    assert loan.update(interest_rate: 4.5), loan.errors.full_messages.to_sentence
    assert_equal @property.id, loan.reload.collateral_account_id
  end

  test "resubmitting the unchanged link on an ineligible asset still saves" do
    @loan.update!(collateral_account: @property)
    @property.update_columns(currency: "EUR")

    loan = Loan.find(@loan.id)

    assert loan.update(collateral_account_id: @property.id, interest_rate: 4.25)
  end

  test "deleting the collateral account unlinks the loan instead of failing" do
    asset = @loan.account.family.accounts.create!(name: "Boat", currency: "USD", balance: 1, accountable: Vehicle.new)
    @loan.update!(collateral_account: asset)

    asset.destroy!

    assert_nil @loan.reload.collateral_account_id
    assert Loan.exists?(@loan.id)
  end

  test "a collateral account knows the loans it secures" do
    @loan.update!(collateral_account: @property)

    assert_equal [ @loan ], @property.secured_loans.to_a
    assert_empty @vehicle.secured_loans
  end

  private
    def create_loan_on(family, collateral:)
      family.accounts.create_and_sync(
        { name: "New loan", balance: 1_000, currency: "USD", owner: users(:family_admin),
          accountable_type: "Loan", accountable_attributes: { collateral_account_id: collateral.id } }
      )
    end
end
