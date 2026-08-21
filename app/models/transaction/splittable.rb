module Transaction::Splittable
  extend ActiveSupport::Concern

  def splittable?
    !transfer? && !entry.split_child? && !entry.split_parent? && !pending? && !entry.excluded?
  end

  # A transaction can become an EMI plan when it meets the same bar as a
  # regular split (single, un-linked, non-transfer, posted expense) and
  # hasn't already been converted.
  #
  # Excludes investment accounts: those transactions can be converted to a
  # Trade instead (see TransactionsController#create_trade_from_transaction),
  # and that path only excludes the source entry -- it has no idea an EMI
  # plan might exist and won't touch its installment schedule. Letting a
  # positive investment-account transaction become an EMI plan would leave
  # the door open to both conversions applying to the same money: a full
  # trade AND a live installment schedule, double-counting in balance
  # reconstruction. Simplest fix is to not let the two paths overlap in
  # the first place.
  #
  # Restricted to kind == "standard": splittable? alone doesn't check kind,
  # so without this a one_time transaction (or, degenerately, a generated
  # emi_fee entry) could be converted. Building the plan always overwrites
  # kind with "emi_purchase" and foreclosure restores whatever the plan
  # recorded as original_kind -- if a non-standard kind were allowed in,
  # that original classification would need to survive the round trip too.
  # Requiring "standard" up front keeps that round trip lossless without
  # having to special-case every other kind's restore behavior.
  def emi_convertible?
    splittable? && standard? && !entry.emi_purchase? && !entry.emi_installment? && entry.amount.positive? && !entry.account.investment?
  end
end
