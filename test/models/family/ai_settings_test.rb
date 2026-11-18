require "test_helper"

class Family::AiSettingsTest < ActiveSupport::TestCase
  setup { @family = families(:dylan_family) }

  test "chat mode is external only for an external assistant type" do
    @family.update!(assistant_type: "external")
    assert @family.chat_mode_external?

    @family.update!(assistant_type: "builtin")
    assert_not @family.chat_mode_external?
  end

  test "ASSISTANT_TYPE still overrides the family's assistant type" do
    @family.update!(assistant_type: "builtin")

    with_env_overrides("ASSISTANT_TYPE" => "external") do
      assert @family.chat_mode_external?
    end
  end

  test "the settings' constants and validations are still Family's" do
    assert_equal %w[builtin external mcp_only], Family::ASSISTANT_TYPES
    assert_equal %w[llm jev], Family::CATEGORIZATION_PROVIDERS

    @family.categorization_provider = "other"
    assert_not @family.valid?
    assert @family.errors.key?(:categorization_provider)
  end
end
