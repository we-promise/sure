class AddAnthropicCacheTokensToLlmUsages < ActiveRecord::Migration[7.2]
  def change
    # Anthropic reports cache_creation_input_tokens (charged at ~1.25x input rate
    # for 5-min TTL) and cache_read_input_tokens (charged at 0.1x input rate).
    # OpenAI usage rows leave these null.
    add_column :llm_usages, :cache_creation_tokens, :integer
    add_column :llm_usages, :cache_read_tokens, :integer

    # Token counters are structurally non-negative; enforce it in the DB
    # (kept nullable — OpenAI rows leave these null).
    add_check_constraint :llm_usages,
      "cache_creation_tokens IS NULL OR cache_creation_tokens >= 0",
      name: "chk_llm_usages_cache_creation_tokens_non_negative"
    add_check_constraint :llm_usages,
      "cache_read_tokens IS NULL OR cache_read_tokens >= 0",
      name: "chk_llm_usages_cache_read_tokens_non_negative"
  end
end
