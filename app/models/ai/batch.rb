# One way to fit the model, for every batched feature. A batch holds at most the model's
# `batch_size` items, and at most
# the tokens left once the rendered prompt and the output reserve are taken from its
# `context_window`. A model with no known window is capped by count only.
#
# Estimates are rough, so a batch that still overflows (ContextTooLong, or an answer cut at the
# output limit) is halved by Ai::Generation and sent again on the same route; only a single item
# that can't fit escalates.
module Ai::Batch
  # Reserved for the answer when the model has no max_output_tokens: today's 512-token budget.
  OUTPUT_RESERVE = 512

  module_function

  def first_slice(items, model:, fixed_tokens:, cost: ->(item) { Assistant::TokenEstimator.estimate(item) })
    cap = model.batch_size || Ai::Config::Model::DEFAULT_BATCH_SIZE
    budget = budget_for(model, fixed_tokens)
    slice = []
    used = 0

    items.each do |item|
      break if slice.size >= cap

      item_cost = cost.call(item)
      break if budget && slice.any? && used + item_cost > budget

      slice << item
      used += item_cost
    end
    slice.presence || items.first(1)   # an item over budget on its own still goes: it escalates if it can't fit
  end

  def budget_for(model, fixed_tokens)
    return unless model.context_window

    model.context_window - (model.max_output_tokens || OUTPUT_RESERVE) - fixed_tokens
  end

  def halves(items) = items.each_slice((items.size / 2.0).ceil).to_a
end
