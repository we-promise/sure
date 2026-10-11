# Shared i18n scope for the Trade Republic settings panel components so the
# prefix can't drift between the editor and the per-connection cards.
module TradeRepublic::PanelTranslatable
  def translation(key, **options)
    helpers.t("settings.providers.trade_republic_panel.#{key}", **options)
  end
end
