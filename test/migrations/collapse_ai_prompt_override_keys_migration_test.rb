# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/migrate/20261106130000_collapse_ai_prompt_override_keys")

class CollapseAiPromptOverrideKeysMigrationTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
  end

  def overrides!(hash) = @family.update_columns(ai_prompt_overrides: hash)

  def run_migration(direction = :up)
    ActiveRecord::Migration.suppress_messages { CollapseAiPromptOverrideKeys.new.public_send(direction) }
    @family.reload.ai_prompt_overrides
  end

  def dropped = DebugLogEntry.where(family: @family, category: CollapseAiPromptOverrideKeys::DROPPED_CATEGORY)

  test "one override per provider becomes the feature's override" do
    overrides!("categorizer_anthropic" => "Sort carefully", "merchant_openai" => "Find shops", "chat_system" => "Be terse")

    assert_equal({ "categorize_transactions" => "Sort carefully", "detect_merchants" => "Find shops", "chat_system" => "Be terse" },
                 run_migration)
    assert_empty dropped
  end

  test "two different overrides keep the one for the provider in use and record the other" do
    overrides!("categorizer_openai" => "OpenAI version", "categorizer_anthropic" => "Claude version")

    with_env_overrides("LLM_PROVIDER" => "anthropic") do
      assert_equal({ "categorize_transactions" => "Claude version" }, run_migration)
    end

    entry = dropped.sole
    assert_equal({ "key" => "categorize_transactions", "text" => "OpenAI version" }, entry.metadata)
    assert_equal [ { key: "categorize_transactions", text: "OpenAI version" } ], @family.dropped_ai_prompt_overrides
  end

  test "OpenAI's is kept by default, and identical overrides drop nothing" do
    overrides!("merchant_openai" => "Same", "merchant_anthropic" => "Same", "categorizer_openai" => "A", "categorizer_anthropic" => "B")

    with_env_overrides("LLM_PROVIDER" => nil) do
      assert_equal({ "detect_merchants" => "Same", "categorize_transactions" => "A" }, run_migration)
    end
    assert_equal [ "B" ], dropped.map { _1.metadata["text"] }
  end

  test "families without old keys are left alone, and down restores both keys" do
    overrides!("chat_system" => "Be terse")
    assert_equal({ "chat_system" => "Be terse" }, run_migration)

    overrides!("categorize_transactions" => "Sort")
    assert_equal({ "categorizer_openai" => "Sort", "categorizer_anthropic" => "Sort" }, run_migration(:down))
  end
end
