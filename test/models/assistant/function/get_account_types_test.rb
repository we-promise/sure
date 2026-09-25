require "test_helper"

class Assistant::Function::GetAccountTypesTest < ActiveSupport::TestCase
  setup do
    @function = Assistant::Function::GetAccountTypes.new(users(:family_admin))
  end

  test "returns every account type with its allowed subtype values" do
    result = @function.call

    assert_equal Accountable::TYPES, result[:account_types].map { |item| item[:type] }

    depository = result[:account_types].find { |item| item[:type] == "Depository" }
    assert_equal Depository::SUBTYPES.keys, depository[:subtypes]

    vehicle = result[:account_types].find { |item| item[:type] == "Vehicle" }
    assert_empty vehicle[:subtypes]
  end

  test "publishes an empty input schema" do
    definition = @function.to_definition

    assert_equal "get_account_types", definition[:name]
    assert_empty definition.dig(:params_schema, :required)
    assert_empty definition.dig(:params_schema, :properties)
  end
end
