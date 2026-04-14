class Provider::Openai::BatchSlicer
  class ContextOverflowError < StandardError; end

  # Splits `items` into sub-batches that respect both a hard item cap and a
  # token-budget cap. Used by auto_categorize / auto_detect_merchants /
  # enhance_provider_merchants so callers can pass larger batches and have the
  # provider fan them out to fit small-context models.
  def self.call(items, max_items:, max_tokens:, fixed_tokens: 0)
    items = Array(items)
    return [] if items.empty?

    available = max_tokens.to_i - fixed_tokens.to_i
    if available <= 0
      raise ContextOverflowError,
            "Fixed prompt tokens (#{fixed_tokens}) exceed context budget (#{max_tokens})"
    end

    batches = []
    current = []
    current_tokens = 0

    items.each do |item|
      item_tokens = Assistant::TokenEstimator.estimate(item)
      if item_tokens > available
        raise ContextOverflowError,
              "Single item requires ~#{item_tokens} tokens, which exceeds available budget (#{available})"
      end

      would_exceed_items  = current.size >= max_items.to_i
      would_exceed_tokens = current_tokens + item_tokens > available

      if would_exceed_items || would_exceed_tokens
        batches << current unless current.empty?
        current = []
        current_tokens = 0
      end

      current << item
      current_tokens += item_tokens
    end

    batches << current unless current.empty?
    batches
  end
end
