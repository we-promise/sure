class Settings::ProviderCard < ApplicationComponent
  MATURITY_LABELS = {
    beta: "settings.providers.maturity.beta",
    alpha: "settings.providers.maturity.alpha"
  }.freeze

  def self.maturity_label(maturity)
    key = MATURITY_LABELS[maturity&.to_sym]
    I18n.t(key) if key
  end

  def initialize(provider_key:, name:, tagline: nil, region: nil, kinds: nil, tier: nil, maturity: :stable)
    @provider_key = provider_key
    @name         = name
    @tagline      = tagline
    @region       = region
    @kinds        = Array(kinds).compact
    @tier         = tier
    @maturity     = maturity.to_sym
  end

  attr_reader :provider_key, :name, :tagline

  def maturity_label
    self.class.maturity_label(@maturity)
  end

  def meta_line
    [ @region, @kinds.join(" / "), @tier ].compact_blank.join(" · ")
  end

  def connect_path
    helpers.connect_form_settings_providers_path(provider_key: @provider_key)
  end

  def filter_data
    {
      providers_filter_target: "card",
      provider_name: @name.to_s.downcase,
      provider_region: @region.to_s.downcase,
      provider_kind: @kinds.map { |kind| kind.to_s.downcase }.join(" ")
    }
  end
end
