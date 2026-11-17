# frozen_string_literal: true

# The dialog for picking which of a connection's accounts to link: several to
# new accounts (select_accounts), or one to an existing account
# (select_existing_account, when `account:` is given). The provider turns its
# API payloads into Options; messages come from its own
# `<key>_items.select_accounts.*` / `select_existing_account.*` keys.
#
# `variant: :classic` reproduces the markup Lunch Flow's dialogs have: a
# hand-written form tag with its own authenticity token field,
# error-coloured rows for accounts without a name, a Cancel link that also
# closes the dialog, and a submit button that is never disabled.
class ProviderItem::AccountSelectionComponent < ApplicationComponent
  Option = Data.define(:id, :name, :metadata) do
    def blank_name? = name.blank?
  end

  attr_reader :item, :options, :accountable_type, :account, :return_to

  def initialize(item:, options:, return_to:, accountable_type: nil, account: nil, variant: :kit)
    @item = item
    @options = options
    @return_to = return_to
    @accountable_type = accountable_type
    @account = account
    @variant = variant
  end

  def classic?
    @variant == :classic
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

  def cancel_data
    classic? ? { turbo_frame: "_top", action: "DS--dialog#close" } : { turbo_frame: "_top" }
  end

  def submit_disabled?
    !classic? && !selectable?
  end

  def blank_name_border_classes
    classic? ? "border-error bg-error/5" : "border-destructive bg-destructive/10"
  end

  def blank_name_text_class
    classic? ? "text-error" : "text-destructive"
  end

  def selection_t(key, **options)
    t("#{provider_key}_items.#{existing_account? ? "select_existing_account" : "select_accounts"}.#{key}", **options)
  end
end
