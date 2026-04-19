require "test_helper"

class AccountImportSecurityTest < ActiveSupport::TestCase
  test "ALLOWED_ACCOUNTABLE_TYPES covers all expected types" do
    expected = %w[
      Depository Investment Crypto
      Property Vehicle OtherAsset
      CreditCard Loan OtherLiability
    ]
    assert_equal expected.sort, AccountImport::ALLOWED_ACCOUNTABLE_TYPES.sort
  end

  test "all ALLOWED_ACCOUNTABLE_TYPES are real constants" do
    AccountImport::ALLOWED_ACCOUNTABLE_TYPES.each do |type|
      assert_nothing_raised { type.constantize }
    end
  end
end
