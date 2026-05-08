# frozen_string_literal: true

class Api::V1::RejectedTransfersController < Api::V1::BaseController
  include Pagy::Backend
  include Api::V1::TransferDecisionFiltering

  before_action :ensure_read_scope
  before_action :set_rejected_transfer, only: :show

  def index
    rejected_transfers_query = apply_transfer_decision_filters(rejected_transfers_scope).order(created_at: :desc)
    @per_page = safe_per_page_param

    @pagy, @rejected_transfers = pagy(
      rejected_transfers_query,
      page: safe_page_param,
      limit: @per_page
    )

    render :index
  rescue Api::V1::TransferDecisionFiltering::InvalidFilterError => e
    render_validation_error(e.message)
  end

  def show
    render :show
  end

  private

    def set_rejected_transfer
      raise ActiveRecord::RecordNotFound unless valid_uuid?(params[:id])

      @rejected_transfer = rejected_transfers_scope.find(params[:id])
    end

    def rejected_transfers_scope
      transfer_decision_scope(RejectedTransfer)
    end
end
