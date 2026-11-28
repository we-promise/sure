# frozen_string_literal: true

# The dialog shown when a provider's API fails while listing accounts.
# Messages come from the provider's own `<key>_items.api_error.*` keys.
class ProviderItem::ApiErrorComponent < ApplicationComponent
  attr_reader :provider_key, :error_message, :return_path

  def initialize(provider_key:, error_message:, return_path:)
    @provider_key = provider_key
    @error_message = error_message
    @return_path = return_path
  end

  def dialog_t(key, **options)
    t("#{provider_key}_items.api_error.#{key}", **options)
  end
end
