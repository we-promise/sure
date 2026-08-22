module Transaction::Splittable
  extend ActiveSupport::Concern

  def splittable?
    !transfer? && !entry.split_child? && !entry.split_parent? && !entry.excluded?
  end
end
