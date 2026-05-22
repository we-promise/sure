# frozen_string_literal: true

class Api::V1::BalancesController < Api::V1::BaseController
  include Pagy::Backend

  before_action :ensure_read_scope
  before_action :set_balance, only: :show
  helper_method :format_money, :money_to_minor_units

  def index
    balances_query = apply_filters(balances_scope).order(date: :desc, created_at: :desc)
    @per_page = safe_per_page_param

    @pagy, @balances = pagy(
      balances_query,
      page: safe_page_param,
      limit: @per_page
    )

    render :index
  rescue InvalidFilterError => e
    render json: {
      error: "validation_failed",
      message: e.message,
      errors: [ e.message ]
    }, status: :unprocessable_entity
  end

  def show
    render :show
  end

  private

    def set_balance
      raise ActiveRecord::RecordNotFound unless valid_uuid?(params[:id])

      @balance = balances_scope.find(params[:id])
    end

    def ensure_read_scope
      authorize_scope!(:read)
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

    def apply_filters(query)
      if params[:account_id].present?
        raise InvalidFilterError, "account_id must be a valid UUID" unless valid_uuid?(params[:account_id])

        query = query.where(account_id: params[:account_id])
      end

      query = query.where(currency: params[:currency].to_s.upcase) if params[:currency].present?
      query = query.where("balances.date >= ?", parse_date_param(:start_date)) if params[:start_date].present?
      query = query.where("balances.date <= ?", parse_date_param(:end_date)) if params[:end_date].present?
      query
    end

    def format_money(money)
      money&.format
    end

    def money_to_minor_units(money)
      (money.amount * money.currency.minor_unit_conversion).round(0).to_i if money
    end
end
