# frozen_string_literal: true

module LunchflowItemsHelper
  # Each account from the Lunch Flow API as a selection row: its name, and the
  # last four characters of its IBAN when it has one, its institution, currency
  # and status.
  def lunchflow_account_options(accounts)
    accounts.map do |account|
      metadata = "#{account[:institution_name]} • #{account[:currency]} • #{account[:status]}"
      metadata = "•#{account[:iban].last(4)} • #{metadata}" if account[:iban].present?

      ProviderItem::AccountSelectionComponent::Option.new(id: account[:id], name: account[:name], metadata: metadata)
    end
  end

  # Every account starts on "Skip"; a depository subtype is preselected when the
  # account's name suggests one.
  def lunchflow_account_setup_defaults(lunchflow_accounts)
    lunchflow_accounts.to_h do |lunchflow_account|
      [ lunchflow_account.id, { account_type: "skip", depository_subtype: lunchflow_depository_subtype(lunchflow_account.name) } ]
    end
  end

  def lunchflow_depository_subtype(account_name)
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
