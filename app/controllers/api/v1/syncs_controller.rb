# frozen_string_literal: true

class Api::V1::SyncsController < Api::V1::BaseController
  include Pagy::Backend

  before_action :ensure_read_scope
  before_action :set_sync, only: [ :show ]

  def index
    @per_page = safe_per_page_param
    @pagy, @syncs = pagy(
      family_syncs_query.preload(:syncable, :children).ordered,
      page: safe_page_param,
      limit: @per_page
    )

    render :index
  end

  def latest
    @sync = family_syncs_query.preload(:syncable, :children).ordered.first
    return render json: { data: nil } unless @sync

    render :show
  end

  def show
    render :show
  end

  private

    def set_sync
      raise ActiveRecord::RecordNotFound unless valid_uuid?(params[:id])

      @sync = family_syncs_query.preload(:syncable, :children).find(params[:id])
    end

    def ensure_read_scope
      authorize_scope!(:read)
    end

    def family_syncs_query
      Sync.for_family(Current.family, resource_owner: Current.user)
    end
end
