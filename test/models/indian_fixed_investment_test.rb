require "test_helper"

class IndianFixedInvestmentTest < ActiveSupport::TestCase
  setup do
    @family = families(:empty)
    @user = @family.users.first
  end

  test "classification returns asset" do
    assert_equal "asset", IndianFixedInvestment.classification
  end

  test "icon returns landmark" do
    assert_equal "landmark", IndianFixedInvestment.icon
  end

  test "color returns correct hex" do
    assert_equal "#875BF7", IndianFixedInvestment.color
  end

  test "SUBTYPES contains Indian investment types" do
    expected_subtypes = %w[ppf ssy nsc scss fd rd pomis kisan_vikas_patra sukanya_samriddhi_2 mahila_samman_savings]
    expected_subtypes.each do |subtype|
      assert IndianFixedInvestment::SUBTYPES.key?(subtype), "Missing subtype: #{subtype}"
    end
  end

  test "PPF is tax exempt" do
    ppf = IndianFixedInvestment.new(subtype: "ppf")
    assert_equal :tax_exempt, ppf.tax_treatment
  end

  test "FD is taxable" do
    fd = IndianFixedInvestment.new(subtype: "fd")
    assert_equal :taxable, fd.tax_treatment
  end

  test "subtypes_grouped_for_select returns grouped options" do
    grouped = IndianFixedInvestment.subtypes_grouped_for_select
    assert grouped.is_a?(Array)
    assert_equal 1, grouped.size
  end

  test "maturity_status returns correct status" do
    investment = IndianFixedInvestment.new
    investment.maturity_date = Date.current + 100
    assert_equal "Active", investment.maturity_status

    investment.maturity_date = Date.current + 60
    assert_equal "Maturing Soon", investment.maturity_status

    investment.maturity_date = Date.current - 1
    assert_equal "Matured", investment.maturity_status
  end

  test "days_to_maturity calculates correctly" do
    investment = IndianFixedInvestment.new
    investment.maturity_date = Date.current + 365
    assert_equal 365, investment.days_to_maturity
  end

  test "can create account with accountable" do
    account = @family.accounts.create!(
      accountable: IndianFixedInvestment.new(subtype: "ppf", interest_rate: "7.1"),
      name: "My PPF Account",
      balance: 500000,
      currency: "INR"
    )

    assert account.persisted?
    assert_equal "ppf", account.subtype
    assert_equal "7.1", account.accountable.interest_rate.to_s
  end
end
