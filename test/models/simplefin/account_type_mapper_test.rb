require "test_helper"

class Simplefin::AccountTypeMapperTest < ActiveSupport::TestCase
  test "holdings present implies Investment" do
    inf = Simplefin::AccountTypeMapper.infer(name: "Vanguard Brokerage", holdings: [ { symbol: "VTI" } ])
    assert_equal "Investment", inf.accountable_type
    assert_nil inf.subtype
  end

  test "retirement inferred when name includes IRA/401k/Roth" do
    [ "My Roth IRA", "401k Fidelity" ].each do |name|
      inf = Simplefin::AccountTypeMapper.infer(name: name, holdings: [ { symbol: "VTI" } ])
      assert_equal "Investment", inf.accountable_type
      assert_equal "retirement", inf.subtype
    end
  end

  test "credit card names map to CreditCard" do
    [ "Chase Credit Card", "VISA Card", "CREDIT" ] .each do |name|
      inf = Simplefin::AccountTypeMapper.infer(name: name)
      assert_equal "CreditCard", inf.accountable_type
    end
  end

  test "loan-like names map to Loan" do
    [ "Mortgage", "Student Loan", "HELOC", "Line of Credit" ].each do |name|
      inf = Simplefin::AccountTypeMapper.infer(name: name)
      assert_equal "Loan", inf.accountable_type
    end
  end

  test "default is Depository" do
    inf = Simplefin::AccountTypeMapper.infer(name: "Everyday Checking")
    assert_equal "Depository", inf.accountable_type
  end
end
