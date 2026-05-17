class Settings::ProviderCard < ApplicationComponent
  MATURITY_LABELS = {
    beta: "settings.providers.maturity.beta",
    alpha: "settings.providers.maturity.alpha"
  }.freeze

  def self.maturity_label(maturity)
    key = MATURITY_LABELS[maturity&.to_sym]
    I18n.t(key) if key
  end

  def initialize(provider_key:, name:, tagline: nil, region: nil, kind: nil, tier: nil,
                 maturity: :stable, logo_bg: "bg-gray-500", logo_text: nil)
    @provider_key = provider_key
    @name         = name
    @tagline      = tagline
    @region       = region
    @kind         = kind
    @tier         = tier
    @maturity     = maturity.to_sym
    @logo_bg      = logo_bg
    @logo_text    = logo_text || name.first(2).upcase
  end

  attr_reader :name, :tagline, :logo_bg, :logo_text

  def maturity_label
    self.class.maturity_label(@maturity)
  end

  def meta_line
    [ @region, @kind, @tier ].compact.join(" · ")
  end

  def connect_path
    helpers.connect_form_settings_providers_path(provider_key: @provider_key)
  end

  def filter_data
    {
      providers_filter_target: "card",
      provider_name: @name.to_s.downcase,
      provider_region: @region.to_s.downcase,
      provider_kind: @kind.to_s.downcase
    }
  end
end
