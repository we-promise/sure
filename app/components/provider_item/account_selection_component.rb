# frozen_string_literal: true

# The dialog for picking which of a connection's accounts to link: several to
# new accounts (select_accounts), or one to an existing account
# (select_existing_account, when `account:` is given). The provider turns its
# API payloads into Options; messages come from its own
# `<key>_items.select_accounts.*` / `select_existing_account.*` keys.
class ProviderItem::AccountSelectionComponent < ApplicationComponent
  Option = Data.define(:id, :name, :metadata) do
    def blank_name? = name.blank?
  end

  attr_reader :item, :options, :accountable_type, :account, :return_to

  def initialize(item:, options:, return_to:, accountable_type: nil, account: nil)
    @item = item
    @options = options
    @return_to = return_to
    @accountable_type = accountable_type
    @account = account
  end

  def provider_key
    item.provider_key
  end

  def existing_account?
    account.present?
  end

  def selectable?
    options.any? { |option| !option.blank_name? }
  end

  def form_url
    helpers.public_send(existing_account? ? :"link_existing_account_#{provider_key}_items_path" : :"link_accounts_#{provider_key}_items_path")
  end

  def cancel_path
    return_to || (existing_account? ? helpers.accounts_path : helpers.new_account_path)
  end

  def selection_t(key, **options)
    t("#{provider_key}_items.#{existing_account? ? "select_existing_account" : "select_accounts"}.#{key}", **options)
  end
end
