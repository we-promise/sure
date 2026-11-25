# frozen_string_literal: true

class Api::V1::HoldingsController < Api::V1::BaseController
  include Pagy::Backend

  before_action :ensure_read_scope
  before_action :set_holding, only: [ :show ]
  before_action :set_search, only: [ :index ]

  def index
    holdings_query = @search.holdings_scope
      .includes(:account, :security).chronological.order(Holding.arel_table[:id])

    @per_page = safe_per_page_param
    @pagy, @holdings = pagy(holdings_query, page: safe_page_param, limit: @per_page)

    render :index
  rescue => e
    log_and_render_error("index", e)
  end

  def show
    render :show
  rescue => e
    log_and_render_error("show", e)
  end

  private

    def set_holding
      @holding = accessible_holdings.find(params[:id])
    rescue ActiveRecord::RecordNotFound
      render json: { error: "not_found", message: "Holding not found" }, status: :not_found
    end

    # Holdings restricted to accounts the token owner can access (owned or shared),
    # not the whole family. Mirrors Api::V1::BalancesController and the web
    # HoldingsController, both of which scope through Account.accessible_by.
    def accessible_holdings
      Holding
        .joins(:account)
        .where(accounts: { status: %w[draft active], id: accessible_account_ids })
    end

    def accessible_account_ids
      @accessible_account_ids ||= current_resource_owner.family.accounts.accessible_by(current_resource_owner).select(:id)
    end

    def set_search
      @search = Holding::Search.new(accessible_holdings, filters: {
        account_id: uuid_filter_param(:account_id),
        account_ids: uuid_list_filter_param(:account_ids),
        security_id: uuid_filter_param(:security_id),
        date: date_filter_param(:date),
        start_date: date_filter_param(:start_date),
        end_date: date_filter_param(:end_date)
      })
    end

    def log_and_render_error(action, exception)
      Rails.logger.error "HoldingsController##{action} error: #{exception.message}"
      Rails.logger.error exception.backtrace.join("\n")
      render json: {
        error: "internal_server_error",
        message: "An unexpected error occurred"
      }, status: :internal_server_error
    end
end
