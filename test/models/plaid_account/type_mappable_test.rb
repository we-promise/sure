require "test_helper"

class PlaidAccount::TypeMappableTest < ActiveSupport::TestCase
  setup do
    class MockProcessor
      include PlaidAccount::TypeMappable
    end

    @mock_processor = MockProcessor.new
  end

  test "maps types to accountables" do
    assert_instance_of Depository, @mock_processor.map_accountable("depository")
    assert_instance_of Investment, @mock_processor.map_accountable("investment")
    assert_instance_of CreditCard, @mock_processor.map_accountable("credit")
    assert_instance_of Loan, @mock_processor.map_accountable("loan")
    assert_instance_of OtherAsset, @mock_processor.map_accountable("other")
  end

  test "maps subtypes" do
    assert_equal "checking", @mock_processor.map_subtype("depository", "checking")
    assert_equal "roth_ira", @mock_processor.map_subtype("investment", "roth")
  end

  test "raises on invalid types" do
    assert_raises PlaidAccount::TypeMappable::UnknownAccountTypeError do
      @mock_processor.map_accountable("unknown")
    end
  end

  test "handles nil subtypes" do
    assert_equal "other", @mock_processor.map_subtype("depository", nil)
    assert_equal "other", @mock_processor.map_subtype("depository", "unknown")
  end

  test "every mapped subtype is a valid subtype of its accountable" do
    PlaidAccount::TypeMappable::TYPE_MAPPING.each do |plaid_type, config|
      accountable_class = config[:accountable]
      next unless accountable_class.const_defined?(:SUBTYPES)

      config[:subtype_mapping].each do |plaid_subtype, subtype|
        assert_includes accountable_class::SUBTYPES.keys, subtype,
          "TYPE_MAPPING maps #{plaid_type}/#{plaid_subtype.inspect} to #{subtype.inspect}, " \
          "which is not a valid #{accountable_class} subtype — syncing such an account fails " \
          "with 'Validation failed: Accountable subtype is not included in the list'"
      end
    end
  end
end
