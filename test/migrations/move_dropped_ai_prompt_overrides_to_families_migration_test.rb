# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/migrate/20261122120000_move_dropped_ai_prompt_overrides_to_families")

class MoveDroppedAiPromptOverridesToFamiliesMigrationTest < ActiveSupport::TestCase
  CATEGORY = MoveDroppedAiPromptOverridesToFamilies::CATEGORY

  setup { @family = families(:dylan_family) }

  def migrate(direction) = ActiveRecord::Migration.suppress_messages { MoveDroppedAiPromptOverridesToFamilies.new.public_send(direction) }

  def set_aside!(key, text, family: @family, at: Time.current)
    DebugLogEntry.create!(category: CATEGORY, level: "warn", message: "dropped", source: "CollapseAiPromptOverrideKeys",
                          family:, metadata: { key:, text: }, created_at: at)
  end

  test "moves each family's set-aside overrides onto the family, keeping its other prompts, and empties the log" do
    @family.update_columns(ai_prompt_overrides: { "chat_system" => "Be terse" })
    set_aside!("categorize_transactions", "Older Claude prompt", at: 2.days.ago)
    set_aside!("categorize_transactions", "Claude prompt", at: 1.day.ago)
    set_aside!("detect_merchants", "Merchant prompt")
    set_aside!("detect_merchants", "Orphan", family: nil)

    migrate(:up)

    @family.reload
    assert_equal({ "chat_system" => "Be terse", "dropped" => { "categorize_transactions" => "Claude prompt", "detect_merchants" => "Merchant prompt" } },
                 @family.ai_prompt_overrides)
    assert_equal [ { key: "categorize_transactions", text: "Claude prompt" }, { key: "detect_merchants", text: "Merchant prompt" } ],
                 @family.dropped_ai_prompt_overrides.sort_by { _1[:key] }
    assert @family.valid?
    assert_not DebugLogEntry.exists?(category: CATEGORY)
  end

  test "down puts them back in the log, so a rollback keeps the text" do
    @family.update_columns(ai_prompt_overrides: { "chat_system" => "Be terse", "dropped" => { "detect_merchants" => "Merchant prompt" } })

    migrate(:down)

    assert_equal({ "chat_system" => "Be terse" }, @family.reload.ai_prompt_overrides)
    entry = DebugLogEntry.find_by!(category: CATEGORY, family: @family)
    assert_equal({ "key" => "detect_merchants", "text" => "Merchant prompt" }, entry.metadata)
  end
end
