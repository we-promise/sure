# frozen_string_literal: true

class Api::V1::SyncController < Api::V1::BaseController
  # Ensure proper scope authorization for write access
  before_action :ensure_write_scope, only: [ :create ]

  def create
    family = current_resource_owner.family

    # Trigger family sync which will:
    # 1. Apply all active rules
    # 2. Sync all accounts
    # 3. Auto-match transfers
    sync = family.sync_later

    @sync = sync
    render :create, status: :accepted
  rescue => e
    Rails.logger.error "SyncController#create error: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")

    render json: {
      error: "internal_server_error",
      message: "Error: #{e.message}"
    }, status: :internal_server_error
  end

  private

    def ensure_write_scope
      authorize_scope!(:write)
    end
end
