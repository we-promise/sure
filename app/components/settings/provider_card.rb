class Settings::ProviderCard < ApplicationComponent
  MATURITY_LABELS = { beta: "Beta", alpha: "Alpha" }.freeze

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

  def maturity_label
    MATURITY_LABELS[@maturity]
  end

  def meta_line
    [ @region, @kind, @tier ].compact.join(" · ")
  end

  def connect_path
    helpers.connect_form_settings_providers_path(provider_key: @provider_key)
  end

  private
    attr_reader :provider_key, :name, :tagline, :region, :kind, :tier, :maturity, :logo_bg, :logo_text
end
