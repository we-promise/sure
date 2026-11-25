# frozen_string_literal: true

class Api::V1::SecuritiesController < Api::V1::BaseController
  include Pagy::Backend
  include Api::V1::SecurityResourceFiltering

  before_action :ensure_read_scope
  before_action :set_security, only: :show
  before_action :set_search, only: :index

  def index
    securities_query = @search.securities_scope.order(:ticker, :exchange_operating_mic, :name)
    @per_page = safe_per_page_param

    @pagy, @securities = pagy(
      securities_query,
      page: safe_page_param,
      limit: @per_page
    )

    render :index
  end

  def show
    render :show
  end

  private

    def set_security
      raise ActiveRecord::RecordNotFound, "Security not found" unless valid_uuid?(params[:id])

      @security = securities_scope.find(params[:id])
    end

    def securities_scope
      Security
        .where(id: scoped_security_ids)
    end

    def set_search
      @search = Security::Search.new(securities_scope, filters: {
        ticker: string_filter_param(:ticker),
        exchange_operating_mic: string_filter_param(:exchange_operating_mic),
        kind: enum_filter_param(:kind, Security::KINDS),
        offline: boolean_filter_param(:offline)
      })
    end
end
