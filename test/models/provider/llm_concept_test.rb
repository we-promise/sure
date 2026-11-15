require "test_helper"

class Provider::LlmConceptTest < ActiveSupport::TestCase
  test "max_items_per_call prefers ENV, then the setting, then 25" do
    Setting.stubs(:llm_max_items_per_call).returns(40)
    with_env_overrides("LLM_MAX_ITEMS_PER_CALL" => "7") do
      assert_equal 7, Provider::LlmConcept.max_items_per_call
    end
    with_env_overrides("LLM_MAX_ITEMS_PER_CALL" => nil) do
      assert_equal 40, Provider::LlmConcept.max_items_per_call
      Setting.stubs(:llm_max_items_per_call).returns(nil)
      assert_equal 25, Provider::LlmConcept.max_items_per_call
    end
  end
end
