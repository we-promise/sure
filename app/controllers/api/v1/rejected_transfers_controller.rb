# frozen_string_literal: true

class Api::V1::RejectedTransfersController < Api::V1::BaseController
  include Pagy::Backend
  include Api::V1::TransferDecisionScoping

  before_action :ensure_read_scope
  before_action :set_rejected_transfer, only: :show
  before_action :set_search, only: :index

  def index
    @per_page = safe_per_page_param
    @pagy, @rejected_transfers = pagy(
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

    def set_rejected_transfer
      raise ActiveRecord::RecordNotFound unless valid_uuid?(params[:id])

      @rejected_transfer = rejected_transfers_scope.find(params[:id])
    end

    def set_search
      @search = transfer_decision_search(rejected_transfers_scope)
    end

    def rejected_transfers_scope
      transfer_decision_scope(RejectedTransfer)
    end
end
