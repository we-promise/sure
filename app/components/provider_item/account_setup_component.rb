# frozen_string_literal: true

# The dialog for choosing an account type (and subtype) for each of a
# connection's imported accounts that is not linked yet. The provider passes
# each account's default type and depository subtype in `defaults`
# ({ provider_account.id => { account_type:, depository_subtype: } }).
# Messages come from the provider's own `<key>_items.setup_accounts.*` and
# `<key>_items.subtype_select.*` keys.
class ProviderItem::AccountSetupComponent < ApplicationComponent
  attr_reader :item, :provider_accounts, :api_error, :account_type_options, :displayable_account_type_options, :subtype_options

  def initialize(item:, provider_accounts:, api_error:, account_type_options:, displayable_account_type_options:, subtype_options:, defaults:)
    @item = item
    @provider_accounts = provider_accounts
    @api_error = api_error
    @account_type_options = account_type_options
    @displayable_account_type_options = displayable_account_type_options
    @subtype_options = subtype_options
    @defaults = defaults
  end

  def provider_key
    item.provider_key
  end

  def default_account_type(provider_account)
    @defaults.fetch(provider_account.id)[:account_type]
  end

  def default_subtype(provider_account, account_type)
    account_type == "Depository" ? @defaults.fetch(provider_account.id)[:depository_subtype] : ""
  end

  def complete_path
    helpers.public_send(:"complete_account_setup_#{provider_key}_item_path", item)
  end

  def setup_t(key, **options)
    t("#{provider_key}_items.setup_accounts.#{key}", **options)
  end
end
