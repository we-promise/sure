# frozen_string_literal: true

module BrexItemsHelper
  BrexAccountDisplay = Struct.new(
    :id,
    :name,
    :kind,
    :currency,
    :status,
    :blank_name,
    keyword_init: true
  ) do
    alias_method :blank_name?, :blank_name
  end

  def brex_account_display(account)
    data = account.with_indifferent_access
    kind = BrexAccount.kind_for(data)
    name = BrexAccount.name_for(data)

    BrexAccountDisplay.new(
      id: data[:id],
      name: name,
      kind: kind,
      currency: BrexAccount.currency_code_from_money(data[:current_balance] || data[:available_balance] || data[:account_limit]),
      status: data[:status],
      blank_name: name.blank?
    )
  end

  def brex_account_options(accounts)
    accounts.map do |account|
      display = brex_account_display(account)
      ProviderItem::AccountSelectionComponent::Option.new(id: display.id, name: display.name, metadata: brex_account_metadata(display))
    end
  end

  def brex_account_metadata(display)
    parts = [
      t("brex_items.account_metadata.provider"),
      display.currency,
      translated_brex_metadata_value("kinds", display.kind),
      translated_brex_metadata_value("statuses", display.status)
    ].compact

    parts.join(t("brex_items.account_metadata.separator"))
  end

  def brex_account_setup_defaults(brex_accounts)
    brex_accounts.to_h do |brex_account|
      [ brex_account.id, { account_type: brex_account.card? ? "CreditCard" : "Depository", depository_subtype: default_brex_depository_subtype(brex_account.name) } ]
    end
  end

  def default_brex_depository_subtype(account_name)
    normalized_name = account_name.to_s.downcase

    if normalized_name.match?(/\bchecking\b|\bchequing\b|\bck\b|demand\s+deposit/)
      "checking"
    elsif normalized_name.match?(/\bsavings\b|\bsv\b/)
      "savings"
    elsif normalized_name.match?(/money\s+market|\bmm\b/)
      "money_market"
    else
      "checking"
    end
  end

  private
    def translated_brex_metadata_value(scope, value)
      key = value.to_s
      return nil if key.blank?

      t("brex_items.#{scope}.#{key}", default: key.titleize)
    end
end
