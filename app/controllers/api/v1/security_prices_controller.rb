# frozen_string_literal: true

class Api::V1::SecurityPricesController < Api::V1::BaseController
  include Pagy::Backend
  include Api::V1::SecurityResourceFiltering

  before_action :ensure_read_scope
  before_action :set_security_price, only: :show

  def index
    security_prices_query = apply_filters(security_prices_scope).order(date: :desc, created_at: :desc)
    @per_page = safe_per_page_param

    @pagy, @security_prices = pagy(
      security_prices_query,
      page: safe_page_param,
      limit: @per_page
    )

    render :index
  rescue Api::V1::SecurityResourceFiltering::InvalidFilterError => e
    render_validation_error(e.message)
  end

  def show
    render :show
  end

  private

    def set_security_price
      raise ActiveRecord::RecordNotFound, "Security price not found" unless valid_uuid?(params[:id])

      @security_price = security_prices_scope.find(params[:id])
    end

    def ensure_read_scope
      authorize_scope!(:read)
    end

    def security_prices_scope
      Security::Price
        .where(security_id: scoped_security_ids)
        .includes(:security)
    end

    def apply_filters(query)
      if params[:security_id].present?
        invalid_filter!("security_id must be a valid UUID") unless valid_uuid?(params[:security_id])

        query = query.where(security_id: params[:security_id])
      end

      query = query.where(currency: params[:currency].to_s.strip.upcase) if params[:currency].present?
      query = query.where("security_prices.date >= ?", parse_date_param(:start_date)) if params[:start_date].present?
      query = query.where("security_prices.date <= ?", parse_date_param(:end_date)) if params[:end_date].present?
      if params.key?(:provisional)
        provisional = parse_boolean_filter_param(:provisional)
        query = query.where(provisional: provisional)
      end
      query
    end
end
