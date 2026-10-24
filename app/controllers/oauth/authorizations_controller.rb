class Oauth::AuthorizationsController < Doorkeeper::AuthorizationsController
  before_action :default_mcp_scope, only: [ :new, :create ]
  around_action :with_authorization_locale

  private

    # Run after Doorkeeper authenticates the resource owner. Unlike Localize,
    # this only sets a request context and never persists a detected preference.
    def with_authorization_locale(&action)
      locale = [ params[:locale], Current.user&.locale, Current.family&.locale ].find do |candidate|
        candidate.is_a?(String) && I18n.available_locales.include?(candidate.to_sym)
      end
      I18n.with_locale(locale || I18n.default_locale, &action)
    end

    def default_mcp_scope
      return if params[:scope].present?

      application = Doorkeeper::Application.find_by(uid: params[:client_id])
      params[:scope] = "read_write" if application&.scopes.to_s.split == [ "read_write" ]
    end
end
