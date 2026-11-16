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
end
