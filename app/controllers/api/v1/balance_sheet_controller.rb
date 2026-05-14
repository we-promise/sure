# frozen_string_literal: true

# Returns the family's balance sheet data (net worth, assets, liabilities)
# with all monetary values converted to the family's primary currency.
class Api::V1::BalanceSheetController < Api::V1::BaseController
  before_action :ensure_read_scope

  # GET /api/v1/balance_sheet
  # Returns net worth, total assets, and total liabilities as Money objects.
  def show
    family = current_resource_owner.family
    balance_sheet = family.balance_sheet(
      user: current_resource_owner,
      include_disabled: include_disabled_accounts?
    )

    render json: {
      currency: family.currency,
      include_disabled: include_disabled_accounts?,
      net_worth: balance_sheet.net_worth_money.as_json,
      assets: balance_sheet.assets.total_money.as_json,
      liabilities: balance_sheet.liabilities.total_money.as_json
    }
  end

  private

    def ensure_read_scope
      authorize_scope!(:read)
    end

    def include_disabled_accounts?
      return @include_disabled_accounts if defined?(@include_disabled_accounts)

      @include_disabled_accounts = ActiveModel::Type::Boolean.new.cast(params[:include_disabled]) || false
    end
end
