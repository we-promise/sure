module CreditCardsHelper
  # The statement cycle is stored as a day of the month, so the form offers a
  # list of days rather than a free-text field: 31 is a real value for a card
  # that closes on the 31st and an impossible one for February, which a number
  # input would happily accept and the validation would then reject.
  #
  # localized_ordinal, not ordinalize: the bare Rails helper always emits
  # English suffixes regardless of the active locale.
  def credit_card_day_of_month_options
    (1..31).map { |day| [ localized_ordinal(day), day ] }
  end

  # How long until the payment is due.
  #
  # Days only. A card is paid in days -- "due in 10 days" is what the issuer
  # prints and what the user is counting -- and converting to weeks or months
  # both rounds away the precision that matters and answers a question nobody
  # asked. An overdue payment is reported as overdue rather than as a negative
  # count, since "due in -4 days" is a formatting slip, not a fact.
  def credit_card_due_countdown(days)
    return nil if days.nil?
    return t("credit_cards.due.overdue", count: days.abs) if days.negative?

    t("credit_cards.due.in_days", count: days)
  end
end
