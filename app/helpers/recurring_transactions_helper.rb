module RecurringTransactionsHelper
  def frequency_label(recurring_transaction)
    RecurringTransaction::FrequencyPreset.label(recurring_transaction)
  end

  # Status is domain state; the tone is how the design system says it. The
  # mapping lives here so every surface badges a status the same way.
  def recurring_status_pill_tone(status)
    case status.to_s
    when "active"    then :success
    when "suggested" then :warning
    else :neutral
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
    # localized_ordinal, not ordinalize: the bare Rails helper always emits
    # English suffixes regardless of the active locale.
    (1..31).map { |day| [ localized_ordinal(day), day ] } +
      [ [ t("recurring_transactions.frequency.last_day"), RecurrenceRule::LAST ] ]
  end

  def frequency_weekday_options
    t("date.day_names").each_with_index.map { |name, index| [ name, index ] }
  end

  def frequency_month_options
    t("date.month_names").compact.each_with_index.map { |name, index| [ name, index + 1 ] }
  end
end
