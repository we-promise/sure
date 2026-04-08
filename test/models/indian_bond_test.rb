require "test_helper"

class IndianBondTest < ActiveSupport::TestCase
  setup do
    @family = families(:empty)
    @user = @family.users.first
  end

  test "classification returns asset" do
    assert_equal "asset", IndianBond.classification
  end

  test "icon returns file-text" do
    assert_equal "file-text", IndianBond.icon
  end

  test "color returns correct hex" do
    assert_equal "#7C3AED", IndianBond.color
  end

  test "SUBTYPES contains bond types" do
    expected_subtypes = %w[govt_securities state_development_loans corporate_bonds psu_bonds infrastructure_bonds capital_gains_bonds tax_free_bonds ncd debentures commercial_paper]
    expected_subtypes.each do |subtype|
      assert IndianBond::SUBTYPES.key?(subtype), "Missing subtype: #{subtype}"
    end
  end

  test "G-Sec is taxable" do
    bond = IndianBond.new(subtype: "govt_securities")
    assert_equal :taxable, bond.tax_treatment
  end

  test "Capital gains bonds are tax exempt" do
    bond = IndianBond.new(subtype: "capital_gains_bonds")
    assert_equal :tax_exempt, bond.tax_treatment
  end

  test "Infrastructure bonds are tax advantaged" do
    bond = IndianBond.new(subtype: "infrastructure_bonds")
    assert_equal :tax_advantaged, bond.tax_treatment
  end

  test "can create account with accountable" do
    account = @family.accounts.create!(
      accountable: IndianBond.new(
        subtype: "govt_securities",
        face_value: 100000,
        coupon_rate: "7.5",
        maturity_date: 10.years.from_now,
        isin: "IN0020231234"
      ),
      name: "My G-Sec Investment",
      balance: 100000,
      currency: "INR"
    )

    assert account.persisted?
    assert_equal "govt_securities", account.subtype
    assert_equal "7.5", account.accountable.coupon_rate.to_s
  end

  test "coupon_rate_display formats correctly" do
    bond = IndianBond.new(coupon_rate: "7.5")
    assert_equal "7.5%", bond.coupon_rate_display
  end

  test "interest_frequency_display formats correctly" do
    bond = IndianBond.new(interest_frequency: "quarterly")
    assert_equal "Quarterly", bond.interest_frequency_display
  end
end
