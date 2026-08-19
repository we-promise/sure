module RecurringTransactionsHelper
  def frequency_label(recurring_transaction)
    RecurringTransaction::FrequencyPreset.label(recurring_transaction)
  end

  def recurring_status_badge_classes(status)
    case status.to_s
    when "active"
      "bg-success/10 text-success"
    when "suggested"
      "bg-warning/10 text-warning"
    else
      "bg-surface-inset text-primary"
    end
  end

  def frequency_preset_options(recurring_transaction)
    options = RecurringTransaction::FrequencyPreset::PRESETS.map do |preset|
      [ t("recurring_transactions.frequency_presets.#{preset}"), preset ]
    end

    if RecurringTransaction::FrequencyPreset.detect(recurring_transaction).key == RecurringTransaction::FrequencyPreset::CUSTOM
      options.unshift([ t("recurring_transactions.frequency_presets.custom"), RecurringTransaction::FrequencyPreset::CUSTOM ])
    end

    options
  end

  def frequency_day_options
    (1..31).map { |day| [ day.ordinalize, day ] } +
      [ [ t("recurring_transactions.frequency.last_day"), RecurrenceRule::LAST ] ]
  end

  def frequency_weekday_options
    t("date.day_names").each_with_index.map { |name, index| [ name, index ] }
  end

  def frequency_month_options
    t("date.month_names").compact.each_with_index.map { |name, index| [ name, index + 1 ] }
  end
end
