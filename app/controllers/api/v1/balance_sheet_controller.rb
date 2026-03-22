# frozen_string_literal: true

class Api::V1::BalanceSheetController < Api::V1::BaseController
  before_action :ensure_read_scope

  # GET /api/v1/balance_sheet
  def show
    family = current_resource_owner.family
    balance_sheet = family.balance_sheet

    render json: {
      currency: family.currency,
      net_worth: balance_sheet.net_worth_money.as_json,
      assets: balance_sheet.assets.total_money.as_json,
      liabilities: balance_sheet.liabilities.total_money.as_json
    }
  end

  private

    def ensure_read_scope
      authorize_scope!(:read)
    end
end
