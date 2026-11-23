class MapsController < ApplicationController
  before_action :require_preview_features!

  def show
    @located_entries = filtered_located_entries

    @map_data = @located_entries.map do |entry|
      {
        id: entry.id,
        lat: entry.location_lat.to_f,
        lng: entry.location_lng.to_f,
        name: entry.location_name,
        transaction_name: entry.name,
        amount: entry.amount_money.format,
        date: entry.date.to_s,
        transaction_path: transaction_path(entry)
      }
    end

    @accounts = Current.family.accounts.accessible_by(Current.user).alphabetically
  end

  private

    def filtered_located_entries
      # Locations live on `entries`, so a trade or valuation could carry one.
      # The popup links back with transaction_path, so only transactions belong
      # on the map.
      scope = Current.family.entries
        .located
        .where(entryable_type: "Transaction")
        .joins(:account)
        .merge(Account.accessible_by(Current.user))

      scope = scope.where(account_id: params[:account_id]) if params[:account_id].present?
      scope = scope.where("entries.date >= ?", params[:start_date]) if params[:start_date].present?
      scope = scope.where("entries.date <= ?", params[:end_date]) if params[:end_date].present?
      scope
    end
end
