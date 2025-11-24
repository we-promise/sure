require "test_helper"

class Simplefin::AccountTypeMapperTest < ActiveSupport::TestCase
  test "holdings present implies Investment" do
    inf = Simplefin::AccountTypeMapper.infer(name: "Vanguard Brokerage", holdings: [ { symbol: "VTI" } ])
    assert_equal "Investment", inf.accountable_type
    assert_nil inf.subtype
  end

  test "explicit retirement tokens map to exact subtypes" do
    cases = {
      "My Roth IRA" => "roth_ira",
      "401k Fidelity" => "401k"
    }
    cases.each do |name, expected_subtype|
      inf = Simplefin::AccountTypeMapper.infer(name: name, holdings: [ { symbol: "VTI" } ])
      assert_equal "Investment", inf.accountable_type
      assert_equal expected_subtype, inf.subtype
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
