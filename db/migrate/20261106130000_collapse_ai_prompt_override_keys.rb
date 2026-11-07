# Prompt overrides become one per feature (ai-plumbing-redesign.md, section 8.3): the provider
# no longer decides which override a family's categorization or merchant detection reads.
#
#   categorizer_openai, categorizer_anthropic -> categorize_transactions
#   merchant_openai,    merchant_anthropic    -> detect_merchants
#
# Where a family has both and they differ, the one for the provider this install uses today
# (LLM_PROVIDER or the saved setting) is kept, and the other goes to a DebugLogEntry that the
# prompts page shows until the family admin next saves.
class CollapseAiPromptOverrideKeys < ActiveRecord::Migration[8.1]
  PAIRS = {
    "categorize_transactions" => %w[categorizer_openai categorizer_anthropic],
    "detect_merchants" => %w[merchant_openai merchant_anthropic]
  }.freeze
  DROPPED_CATEGORY = "ai_prompt_override_dropped".freeze

  class Family < ActiveRecord::Base
    self.table_name = "families"
  end

  def up
    anthropic = llm_provider == "anthropic"

    Family.where("ai_prompt_overrides ?| array[:keys]", keys: PAIRS.values.flatten).find_each do |family|
      overrides = family.ai_prompt_overrides.to_h.dup

      PAIRS.each do |key, (openai_key, anthropic_key)|
        openai, claude = overrides.delete(openai_key).presence, overrides.delete(anthropic_key).presence
        next if openai.nil? && claude.nil?

        kept, other = anthropic ? [ claude || openai, (openai if claude) ] : [ openai || claude, (claude if openai) ]
        overrides[key] = kept
        record_dropped(family, key, other) if other && other != kept
      end

      family.update_columns(ai_prompt_overrides: overrides)
    end
  end

  def down
    Family.where("ai_prompt_overrides ?| array[:keys]", keys: PAIRS.keys).find_each do |family|
      overrides = family.ai_prompt_overrides.to_h.dup
      PAIRS.each do |key, old_keys|
        text = overrides.delete(key)
        old_keys.each { overrides[_1] = text } if text
      end
      family.update_columns(ai_prompt_overrides: overrides)
    end
  end

  private
    def llm_provider
      ENV["LLM_PROVIDER"].presence ||
        select_value("SELECT value FROM settings WHERE var = 'llm_provider'").to_s.delete_prefix("--- ").strip.presence ||
        "openai"
    end

    def record_dropped(family, key, text)
      execute ActiveRecord::Base.sanitize_sql([
        "INSERT INTO debug_log_entries (id, category, level, message, source, family_id, metadata, created_at, updated_at) " \
        "VALUES (gen_random_uuid(), ?, 'warn', ?, ?, ?, ?::jsonb, now(), now())",
        DROPPED_CATEGORY, "A prompt override was dropped when the per-provider overrides merged", self.class.name,
        family.id, { key:, text: }.to_json
      ])
    end
end
