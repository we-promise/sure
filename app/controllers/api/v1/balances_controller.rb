# frozen_string_literal: true

class Api::V1::BalancesController < Api::V1::BaseController
  include Pagy::Backend

  before_action :ensure_read_scope
  before_action :set_balance, only: :show
  before_action :set_search, only: :index
  helper_method :format_money, :money_to_minor_units

  def index
    @per_page = safe_per_page_param

    @pagy, @balances = pagy(
      @search.balances_scope.order(date: :desc, created_at: :desc),
      page: safe_page_param,
      limit: @per_page
    )

    render :index
  end

  def show
    render :show
  end

  private

    def set_balance
      raise ActiveRecord::RecordNotFound unless valid_uuid?(params[:id])

      @balance = balances_scope.find(params[:id])
    end

    def balances_scope
      Balance
        .joins(:account)
        .where(accounts: { id: accessible_account_ids })
        .includes(:account)
    end

    def accessible_account_ids
      @accessible_account_ids ||= current_resource_owner.family.accounts.accessible_by(current_resource_owner).select(:id)
    end

    def set_search
      @search = Balance::Search.new(balances_scope, filters: {
        account_id: uuid_filter_param(:account_id),
        currency: string_filter_param(:currency),
        start_date: date_filter_param(:start_date),
        end_date: date_filter_param(:end_date)
      })
    end

    def format_money(money)
      money&.format
    end

    def money_to_minor_units(money)
      (money.amount * money.currency.minor_unit_conversion).round(0).to_i if money
    end
end
