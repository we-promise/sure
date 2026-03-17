require "test_helper"

class CryptoTest < ActiveSupport::TestCase
  test "tax_treatment defaults to taxable" do
    crypto = Crypto.new
    assert_equal "taxable", crypto.tax_treatment
  end

  test "tax_treatment can be set to tax_deferred" do
    crypto = Crypto.new(tax_treatment: :tax_deferred)
    assert_equal "tax_deferred", crypto.tax_treatment
  end

  test "tax_treatment can be set to tax_exempt" do
    crypto = Crypto.new(tax_treatment: :tax_exempt)
    assert_equal "tax_exempt", crypto.tax_treatment
  end

  test "tax_treatment enum provides predicate methods" do
    crypto = Crypto.new(tax_treatment: :taxable)
    assert crypto.taxable?
    assert_not crypto.tax_deferred?
    assert_not crypto.tax_exempt?

    crypto.tax_treatment = :tax_deferred
    assert_not crypto.taxable?
    assert crypto.tax_deferred?
    assert_not crypto.tax_exempt?
  end

  test "supports_trades? is true only for exchange subtype" do
    assert Crypto.new(subtype: "exchange").supports_trades?
    refute Crypto.new(subtype: "wallet").supports_trades?
    refute Crypto.new(subtype: nil).supports_trades?
  end
end
