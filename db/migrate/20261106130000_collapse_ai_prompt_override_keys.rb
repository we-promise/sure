# Prompt overrides become one per feature: the provider
# no longer decides which override a family's categorization or merchant detection reads.
#
#   categorizer_openai, categorizer_anthropic -> categorize_transactions
#   merchant_openai,    merchant_anthropic    -> detect_merchants
#
# Where a family has both and they differ, the one for the provider this install calls is kept:
# LLM_PROVIDER or the saved setting, unless that provider has no key and the other has, as
# Provider::Registry.preferred_llm_provider falls back. The other goes to a DebugLogEntry that
# the prompts page shows until the family admin next saves.
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
    anthropic = provider_in_use == "anthropic"

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
    def provider_in_use
      order = llm_provider == "anthropic" ? %w[anthropic openai] : %w[openai anthropic]
      order.find { key?(_1) } || order.first
    end

    def key?(provider)
      if provider == "anthropic"
        ENV["ANTHROPIC_ACCESS_TOKEN"].present? || ENV["ANTHROPIC_API_KEY"].present? || setting?("anthropic_access_token")
      else
        openai_token = ENV["OPENAI_ACCESS_TOKEN"].present? || setting?("openai_access_token")
        # A custom URL without a model builds no OpenAI route (LegacyEnvConfig#openai).
        custom_url = ENV["OPENAI_URI_BASE"].present? || setting?("openai_uri_base")
        openai_token && (!custom_url || ENV["OPENAI_MODEL"].present? || setting?("openai_model"))
      end
    end

    def setting?(var)
      value = select_value(ActiveRecord::Base.sanitize_sql([ "SELECT value FROM settings WHERE var = ?", var ]))
      !value.to_s.delete_prefix("---").strip.in?([ "", "null", "~", "''" ])
    end

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
