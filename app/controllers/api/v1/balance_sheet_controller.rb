# frozen_string_literal: true

# Returns the family's balance sheet data (net worth, assets, liabilities)
# with all monetary values converted to the family's primary currency.
class Api::V1::BalanceSheetController < Api::V1::BaseController
  before_action :ensure_read_scope

  # GET /api/v1/balance_sheet
  # Returns net worth, total assets, and total liabilities as Money objects.
  def show
    family = current_resource_owner.family
    balance_sheet = family.balance_sheet(user: current_resource_owner)

    render json: {
      currency: family.currency,
      net_worth: balance_sheet.net_worth_money.as_json,
      assets: balance_sheet.assets.total_money.as_json,
      liabilities: balance_sheet.liabilities.total_money.as_json,
      availability: availability_json(balance_sheet.liquidity)
    }
  end

  private

    # Available vs. locked wealth (Account::Liquidity). Always returned, like
    # the account availability fields: additive, so older clients ignore it.
    def availability_json(overview)
      {
        as_of: overview.date.iso8601,
        available_net_worth: overview.available_net_worth.as_json,
        available_assets: overview.available_assets.as_json,
        bound_assets: overview.bound_assets.as_json,
        short_term_liabilities: overview.short_term_liabilities.as_json,
        upcoming_releases: overview.releases.map do |release|
          {
            account_id: release.account.id,
            account_name: release.account.name,
            date: release.date.iso8601,
            amount: release.amount.as_json,
            auto_renew: release.auto_renew
          }
        end
      }
    end

    def ensure_read_scope
      authorize_scope!(:read)
    end
end
