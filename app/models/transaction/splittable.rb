module Transaction::Splittable
  extend ActiveSupport::Concern

  def splittable?
    !transfer? && !entry.split_child? && !entry.split_parent? && !pending? && !entry.excluded?
  end

  # Whether this split row takes its merchant from its parent: it carries the parent's merchant and
  # nobody pinned it. pass_merchant_to_split_children keeps such rows in step with the parent.
  def follows_parent_merchant?(parent_merchant_id)
    enrichable?(:merchant_id) && merchant_id == parent_merchant_id
  end
end
