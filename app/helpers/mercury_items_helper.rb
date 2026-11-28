# frozen_string_literal: true

module MercuryItemsHelper
  # Each account from the Mercury API as a selection row: its nickname, name or
  # legal business name, then its currency, status and type.
  def mercury_account_options(accounts)
    accounts.map do |account|
      metadata = "Mercury • USD • #{account[:status]}"
      metadata = "#{metadata} • #{account[:type].titleize}" if account[:type].present?

      ProviderItem::AccountSelectionComponent::Option.new(
        id: account[:id],
        name: account[:nickname].presence || account[:name].presence || account[:legalBusinessName].presence,
        metadata: metadata
      )
    end
  end

  # Every account starts on "Skip"; a depository subtype is preselected when the
  # account's name suggests one.
  def mercury_account_setup_defaults(mercury_accounts)
    mercury_accounts.to_h do |mercury_account|
      [ mercury_account.id, { account_type: "skip", depository_subtype: mercury_depository_subtype(mercury_account.name) } ]
    end
  end

  def mercury_depository_subtype(account_name)
    normalized_name = account_name.to_s.downcase

    if normalized_name.match?(/\bchecking\b|\bchequing\b|\bck\b|demand\s+deposit/)
      "checking"
    elsif normalized_name.match?(/\bsavings\b|\bsv\b/)
      "savings"
    elsif normalized_name.match?(/money\s+market|\bmm\b/)
      "money_market"
    else
      ""
    end
  end
end
