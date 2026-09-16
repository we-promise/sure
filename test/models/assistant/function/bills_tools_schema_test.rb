require "test_helper"

class Assistant::Function::BillsToolsSchemaTest < ActiveSupport::TestCase
  BILLS_TOOLS = [
    Assistant::Function::GetBills,
    Assistant::Function::GetBillDetails,
    Assistant::Function::GetPaycheckPlan,
    Assistant::Function::GetBillAudit,
    Assistant::Function::CreateBill,
    Assistant::Function::UpdateBill,
    Assistant::Function::RecordBillPayment
  ].freeze

  # Strict function calling requires every declared property in `required`;
  # a strict tool with an optional property is rejected wholesale by strict
  # providers. Scoped to the bills tools: the pre-existing tools' strictness
  # is reworked by the assistant-upgrade PR (#3064), not here.
  test "strict bills tools declare every property as required" do
    each_definition do |name, definition|
      next unless definition[:strict]

      schema = definition[:params_schema]
      property_keys = schema[:properties].keys.map(&:to_s)
      required_keys = Array(schema[:required]).map(&:to_s)

      assert_equal property_keys.sort, required_keys.sort,
        "#{name} is strict but properties #{property_keys - required_keys} are not required"
    end
  end

  # Data-driven enums put per-family values into the schema, which breaks
  # strict validators the moment a family has none (the empty-enum incident)
  # and bloats every request. Bills tools use static enums only.
  test "bills tool enums are static and never empty" do
    each_definition do |name, definition|
      definition[:params_schema][:properties].each do |key, property|
        enums = [ property[:enum], property.dig(:items, :enum) ].compact
        enums.each do |values|
          assert values.any?, "#{name}.#{key} declares an empty enum"
        end
      end
    end
  end

  # The registry is shared with the public /mcp endpoint: being listed makes a
  # tool callable by external agents. Bills is a preview feature, so its tools
  # ride the per-user preview flag -- present for an opted-in user, absent from
  # the default set. This test documents both halves.
  test "the bills tools are preview-gated in the registry" do
    user_with_preview = users(:family_admin)
    user_with_preview.update!(
      preferences: (user_with_preview.preferences || {}).merge("preview_features_enabled" => true)
    )

    preview_classes = Assistant.function_classes(user_with_preview)
    default_classes = Assistant.function_classes(nil)

    BILLS_TOOLS.each do |tool|
      assert_includes preview_classes, tool
      assert_not_includes default_classes, tool
    end
  end

  private

    def each_definition
      user = users(:family_admin)

      BILLS_TOOLS.each do |fn_class|
        fn = fn_class.new(user)
        yield fn.name, fn.to_definition
      end
    end
end
