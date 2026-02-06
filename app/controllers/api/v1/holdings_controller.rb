# frozen_string_literal: true

class Api::V1::HoldingsController < Api::V1::BaseController
  include Pagy::Backend

  before_action :ensure_read_scope
  before_action :set_holding, only: [ :show ]

  def index
    family = current_resource_owner.family
    holdings_query = family.holdings.joins(:account).where(accounts: { status: [ "draft", "active" ] })

    holdings_query = apply_filters(holdings_query)
    holdings_query = holdings_query.includes(:account, :security).chronological

    @pagy, @holdings = pagy(
      holdings_query,
      page: safe_page_param,
      limit: safe_per_page_param
    )
    @per_page = safe_per_page_param

    render :index
  rescue ActionController::BadRequest => e
    render json: { error: "bad_request", message: e.message }, status: :bad_request
  rescue => e
    Rails.logger.error "HoldingsController#index error: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    render json: {
      error: "internal_server_error",
      message: "Error: #{e.message}"
    }, status: :internal_server_error
  end

  def show
    render :show
  rescue => e
    Rails.logger.error "HoldingsController#show error: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    render json: {
      error: "internal_server_error",
      message: "Error: #{e.message}"
    }, status: :internal_server_error
  end

  private

    def set_holding
      family = current_resource_owner.family
      @holding = family.holdings.joins(:account).where(accounts: { status: [ "draft", "active" ] }).find(params[:id])
    rescue ActiveRecord::RecordNotFound
      render json: { error: "not_found", message: "Holding not found" }, status: :not_found
    end

    def ensure_read_scope
      authorize_scope!(:read)
    end

    def apply_filters(query)
      if params[:account_id].present?
        query = query.where(account_id: params[:account_id])
      end
      if params[:account_ids].present?
        query = query.where(account_id: Array(params[:account_ids]))
      end
      if params[:date].present?
        query = query.where(date: parse_date!(params[:date]))
      end
      if params[:start_date].present?
        query = query.where("holdings.date >= ?", parse_date!(params[:start_date]))
      end
      if params[:end_date].present?
        query = query.where("holdings.date <= ?", parse_date!(params[:end_date]))
      end
      if params[:security_id].present?
        query = query.where(security_id: params[:security_id])
      end
      query
    end

    def safe_page_param
      page = params[:page].to_i
      page > 0 ? page : 1
    end

    def safe_per_page_param
      per_page = params[:per_page].to_i
      (1..100).cover?(per_page) ? per_page : 25
    end

    def parse_date!(value)
      Date.parse(value)
    rescue Date::Error, ArgumentError, TypeError
      raise ActionController::BadRequest, "Invalid date: #{value}"
    end
end
