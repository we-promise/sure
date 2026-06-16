require "test_helper"

class Brazil::BankLogoResolverTest < ActiveSupport::TestCase
  test "resolves a curated local logo asset from the bank logo key" do
    bank = Brazil::Bank.new(short_name: "Nu Pagamentos", logo_key: "nubank")

    assert_equal "brazil/banks/nubank.svg", Brazil::BankLogoResolver.new(bank).asset_path
  end

  test "falls back to initials for banks without a curated logo" do
    bank = Brazil::Bank.new(short_name: "Cooperativa Central de Credito")

    assert_nil Brazil::BankLogoResolver.new(bank).asset_path
    assert_equal "CC", Brazil::BankLogoResolver.new(bank).fallback_initials
  end
end
