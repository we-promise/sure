require "ostruct"

class Transactions::SearchesController < ApplicationController
  layout false

  def menu
    @q = menu_search_params
    @filter_merchants = Current.family.cached_assigned_merchants_for(Current.user)
  end

  private
    def menu_search_params
      params.fetch(:q, {}).permit(
        :search, :start_date, :end_date, :amount, :amount_operator,
        :active_accounts_only,
        accounts: [], account_ids: [],
        categories: [], merchants: [], types: [], tags: [], status: []
      ).to_h.compact_blank
    end
end
