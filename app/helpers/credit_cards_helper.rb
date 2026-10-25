module CreditCardsHelper
  def credit_card_day_of_month_options
    (1..31).map { |day| [ localized_ordinal(day), day ] }
  end

  def credit_card_due_countdown(days)
    return nil if days.nil?
    return t("credit_cards.due.overdue", count: days.abs) if days.negative?

    t("credit_cards.due.in_days", count: days)
  end
end
