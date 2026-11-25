# Shared i18n scope and identifier masking for the Trade Republic settings
# panel components, so neither can drift between the cards.
module TradeRepublic::PanelTranslatable
  def translation(key, **options)
    helpers.t("settings.providers.trade_republic_panel.#{key}", **options)
  end

  # "Phone •••• 4567": the cards show only the last 4 characters.
  def masked_identifier(kind, last4)
    "#{translation("identifier_#{kind}")} \u2022\u2022\u2022\u2022 #{last4}" if last4
  end

  def last4(value)
    cleaned = value.to_s.delete(" ")
    cleaned.last(4) if cleaned.size >= 4
  end
end
