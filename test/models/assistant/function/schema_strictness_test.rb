require "test_helper"

class Assistant::Function::SchemaStrictnessTest < ActiveSupport::TestCase
  # Strict function calling requires every declared property to appear in
  # `required`. A strict tool with an optional property produces an invalid
  # schema that strict providers reject wholesale, so this walks the entire
  # registry (preview tools included) to keep the class of bug out for good.
  test "strict functions declare every property as required" do
    user = users(:family_admin)
    user.update!(preferences: (user.preferences || {}).merge("preview_features_enabled" => true))

    function_classes = Assistant.function_classes(user)

    # Every shipped tool declares optional properties and so opts out of strict
    # mode; the walk below therefore asserts nothing today and exists to catch
    # the first tool that keeps the default. Guard the registry itself so a
    # future empty or broken lookup cannot make this test vacuous unnoticed.
    assert_operator function_classes.size, :>, 15,
      "the tool registry looks empty or truncated, so the strictness walk would prove nothing"

    function_classes.each do |fn_class|
      fn = fn_class.new(user)
      definition = fn.to_definition
      next unless definition[:strict]

      schema = definition[:params_schema]
      property_keys = schema[:properties].keys.map(&:to_s)
      required_keys = Array(schema[:required]).map(&:to_s)

      assert_equal property_keys.sort, required_keys.sort,
        "#{fn.name} is strict but properties #{property_keys - required_keys} are not required"
    end
  end
end
