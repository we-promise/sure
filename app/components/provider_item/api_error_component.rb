# frozen_string_literal: true

# The dialog shown when a provider's API fails while listing accounts.
# Messages come from the provider's own `<key>_items.api_error.*` keys. A
# provider whose dialog words things differently passes its own `heading:`,
# `issues:` (label and description pairs) and `link_text:`.
class ProviderItem::ApiErrorComponent < ApplicationComponent
  ISSUES = %w[invalid_token expired_credentials permissions network service].freeze

  attr_reader :provider_key, :error_message, :return_path

  def initialize(provider_key:, error_message:, return_path:, heading: nil, issues: nil, link_text: nil)
    @provider_key = provider_key
    @error_message = error_message
    @return_path = return_path
    @heading = heading
    @issues = issues
    @link_text = link_text
  end

  def heading
    @heading || dialog_t("heading")
  end

  def issues
    @issues || ISSUES.map { |issue| [ dialog_t("#{issue}_label"), dialog_t(issue) ] }
  end

  def link_text
    @link_text || dialog_t("settings_link")
  end

  def dialog_t(key, **options)
    t("#{provider_key}_items.api_error.#{key}", **options)
  end
end
