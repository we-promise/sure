# frozen_string_literal: true

# The dialog shown when a provider has no credentialed connection to list
# accounts from.
# Messages come from the provider's own `<key>_items.setup_required.*` keys. A
# provider whose dialog words things differently passes its own `heading:`,
# `description:`, `steps_title:`, `steps:` and `link_text:`, and
# `notice: :alert` shows the heading and description in a warning alert
# instead of beside an icon.
class ProviderItem::SetupRequiredComponent < ApplicationComponent
  STEPS = %w[open_settings_html find_section_html enter_token return_to_link].freeze

  attr_reader :provider_key, :notice

  def initialize(provider_key:, notice: :icon, heading: nil, description: nil, steps_title: nil, steps: nil, link_text: nil)
    @provider_key = provider_key
    @notice = notice
    @heading = heading
    @description = description
    @steps_title = steps_title
    @steps = steps
    @link_text = link_text
  end

  def heading
    @heading || dialog_t("heading")
  end

  def description
    @description || dialog_t("description")
  end

  def steps_title
    @steps_title || dialog_t("setup_steps")
  end

  def steps
    @steps || STEPS.map { |step| dialog_t("steps.#{step}") }
  end

  def link_text
    @link_text || dialog_t("settings_link")
  end

  def dialog_t(key, **options)
    t("#{provider_key}_items.setup_required.#{key}", **options)
  end
end
