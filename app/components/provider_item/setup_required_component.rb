# frozen_string_literal: true

# The dialog shown when a provider has no credentialed connection to list
# accounts from.
# Messages come from the provider's own `<key>_items.setup_required.*` keys.
class ProviderItem::SetupRequiredComponent < ApplicationComponent
  attr_reader :provider_key

  def initialize(provider_key:)
    @provider_key = provider_key
  end

  def dialog_t(key, **options)
    t("#{provider_key}_items.setup_required.#{key}", **options)
  end
end
