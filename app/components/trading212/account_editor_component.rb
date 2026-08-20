class Trading212::AccountEditorComponent < ApplicationComponent
  def initialize(items: nil, family:)
    @items = items || family.trading212_items.ordered
    @family = family
  end

  attr_reader :items

  def new_item
    @new_item ||= @family.trading212_items.build(name: translation("default_account_name"))
  end

  def environment_options
    [
      [ translation("environment_live"), "live" ],
      [ translation("environment_demo"), "demo" ]
    ]
  end

  def currency_options
    Money::Currency.as_options.map { |currency| [ "#{currency.name} (#{currency.iso_code})", currency.iso_code ] }
  end

  def translation(key, **options)
    helpers.t("settings.providers.trading212_panel.#{key}", **options)
  end
end
