module ScalableAuthorization
  extend ActiveSupport::Concern

  included do
    before_action :protect_scalable_connection
    before_action :require_preview_features!
    before_action :require_admin!
  end

  private

    def protect_scalable_connection
      response.headers["Cache-Control"] = "no-store, private, max-age=0"
      response.headers["Pragma"] = "no-cache"
      response.headers["Referrer-Policy"] = "no-referrer"
      return head :forbidden if Current.session&.active_impersonator_session_id.present?

      head :not_found unless Rails.application.config.app_mode.self_hosted? && Current.family.can_connect_scalable?
    end

    def owned_scalable_items
      Current.family.scalable_items.owned_by(Current.user)
    end

    def current_session_id
      Current.session&.id.to_s
    end
end
