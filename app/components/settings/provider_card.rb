class Settings::ProviderCard < ApplicationComponent
  MATURITY_LABELS = {
    beta: "settings.providers.maturity.beta",
    alpha: "settings.providers.maturity.alpha"
  }.freeze

  def self.maturity_label(maturity)
    key = MATURITY_LABELS[maturity&.to_sym]
    I18n.t(key) if key
  end

  def initialize(provider_key:, name:, tagline: nil, region: nil, kinds: nil, tier: nil, maturity: :stable, external_link: nil)
    @provider_key = provider_key
    @name         = name
    @tagline      = tagline
    @region       = region
    @kinds        = Array(kinds).compact
    @tier         = tier
    @maturity     = maturity.to_sym
    @external_link = external_link
  end

  attr_reader :provider_key, :name, :tagline, :external_link

  def container(&block)
    classes = "bg-container shadow-border-xs rounded-xl p-4 flex flex-col gap-2.5 text-primary"
    if external_link
      tag.div(class: classes, data: filter_data, &block)
    else
      link_to(connect_path,
        class: "#{classes} hover:bg-surface-inset transition-colors focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-alpha-black-300",
        data: { turbo_frame: "drawer", turbo_prefetch: "false" }.merge(filter_data), &block)
    end
  end

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
