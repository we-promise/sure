require "test_helper"

class AccountImportSecurityTest < ActiveSupport::TestCase
  test "ALLOWED_ACCOUNTABLE_TYPES mirrors Accountable::TYPES (guards against drift)" do
    assert_equal Accountable::TYPES.sort, AccountImport::ALLOWED_ACCOUNTABLE_TYPES.sort
  end

  test "all ALLOWED_ACCOUNTABLE_TYPES resolve via Accountable.from_type" do
    AccountImport::ALLOWED_ACCOUNTABLE_TYPES.each do |type|
      assert_not_nil Accountable.from_type(type), "#{type} should resolve to a class"
    end
  end

  test "Accountable.from_type rejects unknown input" do
    assert_nil Accountable.from_type("ActiveRecord::Base")
    assert_nil Accountable.from_type("NotAClass")
    assert_nil Accountable.from_type(nil)
    assert_nil Accountable.from_type("")
  end
end
