class AddAnthropicCacheTokensToLlmUsages < ActiveRecord::Migration[7.2]
  def change
    # Anthropic reports cache_creation_input_tokens (charged at ~1.25x input rate
    # for 5-min TTL) and cache_read_input_tokens (charged at 0.1x input rate).
    # OpenAI usage rows leave these null.
    add_column :llm_usages, :cache_creation_tokens, :integer
    add_column :llm_usages, :cache_read_tokens, :integer
  end
end
