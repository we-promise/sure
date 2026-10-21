class Provider::Openai::BatchSlicer
  class ContextOverflowError < StandardError; end

  # Splits `items` into sub-batches that fit the token budget, so a batch too
  # big for a small-context model fans out instead of failing.
  def self.call(items, max_tokens:, fixed_tokens: 0)
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

      if current_tokens + item_tokens > available
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
