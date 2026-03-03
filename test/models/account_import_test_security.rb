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
  test "ALLOWED_ACCOUNTABLE_TYPES blocks forbidden types before constantize" do
    # Simulate what import! does when it gets a forbidden type from a mapping
    forbidden_types = %w[Kernel::Object User Family Session]

    forbidden_types.each do |type|
      allowed = AccountImport::ALLOWED_ACCOUNTABLE_TYPES.include?(type)
      assert_not allowed, "#{type} should not be in ALLOWED_ACCOUNTABLE_TYPES"
    end
  end

  test "ALLOWED_ACCOUNTABLE_TYPES allows all valid accountable types" do
    AccountImport::ALLOWED_ACCOUNTABLE_TYPES.each do |type|
      assert_includes AccountImport::ALLOWED_ACCOUNTABLE_TYPES, type
      assert_nothing_raised { type.constantize }
    end
  end
end
