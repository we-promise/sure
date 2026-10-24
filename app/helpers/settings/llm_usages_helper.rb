module Settings::LlmUsagesHelper
  LLM_USAGE_OPERATIONS = %w[
    auto_categorize auto_detect_merchants enhance_provider_merchants suggest_bill_setup
    process_pdf process_pdf_vision extract_bank_statement chat
  ].freeze

  def llm_usage_operation_label(operation)
    return operation unless LLM_USAGE_OPERATIONS.include?(operation)

    t("settings.llm_usages.operations.#{operation}")
  end

  def llm_usage_cost(value, precision: nil)
    return "N/A" if value.nil?

    # Keep the existing display rounding: fixed precision in summaries and
    # BigDecimal#round(4) with its retained decimal places for individual rows.
    amount = precision ? Kernel.format("%.#{precision}f", value) : value.round(4).to_s("F")
    decimal_places = precision || amount.split(".").last.length

    number_to_currency(amount, unit: "$", precision: decimal_places,
      significant: false, strip_insignificant_zeros: false, locale: I18n.locale)
  end
end
