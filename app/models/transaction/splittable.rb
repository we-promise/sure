module Transaction::Splittable
  extend ActiveSupport::Concern

  def splittable?
    !transfer? && !refund_linked? && !entry.split_child? && !entry.split_parent? && !pending? && !entry.excluded?
  end
end
