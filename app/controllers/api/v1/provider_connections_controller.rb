# frozen_string_literal: true

class Api::V1::ProviderConnectionsController < Api::V1::BaseController
  before_action :ensure_read_scope

  def index
    hidden = ProviderConnectionStatus.hidden_provider_keys(preview_enabled: current_resource_owner.preview_features_enabled?)
    @provider_connections = ProviderConnectionStatus.for_family(current_resource_owner.family, except: hidden)
    render :index
  rescue StandardError => e
    Rails.logger.error "ProviderConnectionsController#index error: #{e.message}"
    e.backtrace&.each { |line| Rails.logger.error line }

    render_json({
      error: "internal_server_error",
      message: "An unexpected error occurred"
    }, status: :internal_server_error)
  end

  private

    def ensure_read_scope
      authorize_scope!(:read)
    end
end
