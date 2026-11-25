# frozen_string_literal: true

class Api::V1::TransfersController < Api::V1::BaseController
  include Pagy::Backend
  include Api::V1::TransferDecisionScoping

  before_action :ensure_read_scope
  before_action :set_transfer, only: :show
  before_action :set_search, only: :index

  def index
    @per_page = safe_per_page_param
    @pagy, @transfers = pagy(
      @search.transfers_scope.order(created_at: :desc),
      page: safe_page_param,
      limit: @per_page
    )

    render :index
  end

  def show
    render :show
  end

  private

    def set_transfer
      raise ActiveRecord::RecordNotFound unless valid_uuid?(params[:id])

      @transfer = transfers_scope.find(params[:id])
    end

    def set_search
      @search = transfer_decision_search(transfers_scope, status: enum_filter_param(:status, Transfer.statuses.keys))
    end

    def transfers_scope
      transfer_decision_scope(Transfer)
    end
end
