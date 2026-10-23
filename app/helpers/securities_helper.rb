module SecuritiesHelper
  def security_price_provider_name(provider_key)
    return t("securities.providers.unknown") if provider_key.blank?

    t("securities.providers.#{provider_key}", default: provider_key.to_s.humanize)
  end

  def security_price_source_label(security)
    source = security.price_source
    return t("securities.price_source.none") if source.status == :none

    t("securities.price_source.#{source.status}", provider: security_price_provider_name(source.provider))
  end
end
