module Transaction::Splittable
  extend ActiveSupport::Concern

  def splittable?
    !transfer? && !entry.split_child? && !entry.split_parent? && !pending? && !entry.excluded?
  end

  # A transaction can become an EMI plan when it meets the same bar as a
  # regular split (single, un-linked, non-transfer, posted expense) and
  # hasn't already been converted.
  def emi_convertible?
    splittable? && !entry.emi_purchase? && !entry.emi_installment? && entry.amount.positive?
  end
end
