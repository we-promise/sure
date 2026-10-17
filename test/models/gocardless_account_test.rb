require "test_helper"

# The balance sign is the highest-stakes mapping here. Sure stores a liability as a
# POSITIVE amount owed and subtracts it from net worth; GoCardless follows the bank's
# convention where a card you owe money on reports NEGATIVE. Storing that verbatim makes
# debt add to net worth. Against two real NatWest cards this read +£18,759 instead of
# -£12,088: still a plausible-looking number, which is what makes it dangerous.
class GocardlessAccountTest < ActiveSupport::TestCase
  setup do
    @account = GocardlessAccount.allocate
  end

  test "maps ISO 20022 cash account types to accountable types" do
    assert_equal "CreditCard", GocardlessAccount.accountable_type_for("CARD")
    assert_equal "Depository", GocardlessAccount.accountable_type_for("CACC")
    assert_equal "Depository", GocardlessAccount.accountable_type_for("SVGS")
    assert_equal "Loan", GocardlessAccount.accountable_type_for("LOAN")
  end

  test "is case insensitive about the cash account type" do
    assert_equal "CreditCard", GocardlessAccount.accountable_type_for("card")
  end

  test "returns nil for an unknown cash account type so the caller can fall back" do
    assert_nil GocardlessAccount.accountable_type_for("WHAT")
    assert_nil GocardlessAccount.accountable_type_for(nil)
  end

  test "classifies card and loan accounts as liabilities" do
    assert GocardlessAccount.liability?("CARD")
    assert GocardlessAccount.liability?("LOAN")
    assert_not GocardlessAccount.liability?("CACC")
    assert_not GocardlessAccount.liability?(nil)
  end

  test "negates a card balance so money owed becomes a positive liability" do
    assert_equal BigDecimal("7863.92"),
                 @account.send(:normalised_balance, BigDecimal("-7863.92"), "CARD")
  end

  test "leaves a current account balance untouched" do
    assert_equal BigDecimal("3335.71"),
                 @account.send(:normalised_balance, BigDecimal("3335.71"), "CACC")
  end

  test "a card in credit becomes a negative liability rather than more debt" do
    # Negating, not taking the absolute value: an overpaid card reports positive and
    # genuinely reduces what is owed.
    assert_equal BigDecimal("-50.00"),
                 @account.send(:normalised_balance, BigDecimal("50.00"), "CARD")
  end

  test "passes nil through rather than coercing it to zero" do
    assert_nil @account.send(:normalised_balance, nil, "CARD")
  end

  test "prefers the interimAvailable balance over whatever happens to be first" do
    balances = [
      { "balanceType" => "closingBooked", "balanceAmount" => { "amount" => "100.00" } },
      { "balanceType" => "interimAvailable", "balanceAmount" => { "amount" => "92.50" } }
    ].map(&:with_indifferent_access)

    assert_equal BigDecimal("92.5"), @account.send(:extract_balance, balances)
  end

  test "falls back to the first balance when no preferred type is present" do
    balances = [ { "balanceType" => "somethingElse", "balanceAmount" => { "amount" => "7.00" } }.with_indifferent_access ]

    assert_equal BigDecimal("7.0"), @account.send(:extract_balance, balances)
  end
end
