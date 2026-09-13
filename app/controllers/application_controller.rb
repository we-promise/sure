class ApplicationController < ActionController::Base
  include RestoreLayoutPreferences, Onboardable, Localize, AutoSync, Authentication, Invitable,
          SelfHostable, StoreLocation, Impersonatable, Breadcrumbable,
          FeatureGuardable, Notifiable, SafePagination, AccountAuthorizable,
          ProviderAccountLinking, PreviewGateable
  include Pundit::Authorization
  include CodespacesForgeryProtection
  include DailyWebUsageTracking

  include Pagy::Backend

  # Pundit uses current_user by default, but this app uses Current.user
  def pundit_user
    Current.user
  end

  before_action :detect_os
  before_action :set_default_chat
  before_action :set_active_storage_url_options

  helper_method :demo_config, :demo_host_match?, :show_demo_warning?, :current_sidekiq_health

  private
    def accept_pending_invitation_for(user)
      return false if user.blank?

      token = session[:pending_invitation_token]
      return false if token.blank?

      invitation = Invitation.pending.find_by(token: token.to_s)
      return false unless invitation
      return false unless invitation.accept_for(user)

      session.delete(:pending_invitation_token)
      true
    end

    def store_pending_invitation_if_valid
      token = params[:invitation].to_s.presence
      return if token.blank?

      invitation = Invitation.pending.find_by(token: token)
      session[:pending_invitation_token] = token if invitation
    end

    def require_admin!
      return if Current.user&.admin?

      respond_to do |format|
        format.html { redirect_to accounts_path, alert: t("shared.require_admin") }
        format.turbo_stream { head :forbidden }
        format.json { head :forbidden }
        format.any { head :forbidden }
      end
    end

    # Guests are read-only by design: they may view family configuration but
    # never change it.
    def require_non_guest!
      return if Current.user && !Current.user.guest?

      respond_to do |format|
        format.html { redirect_to accounts_path, alert: t("shared.require_non_guest") }
        format.turbo_stream { head :forbidden }
        format.json { head :forbidden }
        format.any { head :forbidden }
      end
    end

    # Provider panels post from the page (connection row or drawer), so Turbo
    # asks for a stream without sending a Turbo-Frame header.
    def turbo_panel_request?
      turbo_frame_request? || request.format.turbo_stream?
    end

    # Set by a panel form whose action also serves another page with the same
    # Turbo request, such as a Sync that the Accounts page posts to as well.
    def provider_panel_form?
      params[:source] == "panel"
    end

    # Re-renders a Bank sync panel where it was posted from, with the alert in
    # the panel or the notice as a flash. `key` is the panel's FAMILY_PANELS key.
    # A request without Turbo is redirected with the flash instead.
    def render_provider_panel(key, notice: nil, alert: nil, fallback_path: settings_providers_path, **locals)
      return redirect_to(fallback_path, notice: notice, alert: alert, status: :see_other) unless turbo_panel_request?

      panel = Settings::ProvidersController::FAMILY_PANELS_BY_KEY.fetch(key)
      flash.now[:notice] = notice if notice
      render turbo_stream: [
        turbo_stream.replace(
          "#{panel[:turbo_id]}-providers-panel",
          partial: "settings/providers/#{panel[:partial]}",
          locals: { error_message: alert, **locals }
        ),
        *flash_notification_stream_items
      ], status: alert ? :unprocessable_entity : :ok
    end

    def detect_os
      user_agent = request.user_agent
      @os = case user_agent
      when /Windows/i then "windows"
      when /Macintosh/i then "mac"
      when /Linux/i then "linux"
      when /Android/i then "android"
      when /iPhone|iPad/i then "ios"
      else ""
      end
    end

    # By default, we show the user the last chat they interacted with
    def set_default_chat
      @last_viewed_chat = Current.user&.last_viewed_chat
      @chat = @last_viewed_chat
    end

    def set_active_storage_url_options
      ActiveStorage::Current.url_options = {
        protocol: request.protocol,
        host: request.host,
        port: request.optional_port
      }
    end

    def demo_config
      Rails.application.config_for(:demo)
    rescue RuntimeError, Errno::ENOENT, Psych::SyntaxError
      nil
    end

    def demo_host_match?(demo = demo_config)
      return false unless demo.is_a?(Hash) && demo["hosts"].present?

      demo["hosts"].include?(request.host)
    end

    def show_demo_warning?
      demo_host_match?
    end

    # Returns the current Sidekiq health snapshot in self-hosted mode and
    # `nil` in managed mode. Memoized per request and additionally cached
    # across requests by `SidekiqHealth.current`, so an authenticated page
    # render adds at most one Redis round-trip per cache window — not three
    # per request. Returns `nil` (not a healthy stand-in) in managed mode
    # so callers must explicitly handle the "check disabled" case; the
    # banner already gates on `Current.user&.super_admin?` and `present?`.
    def current_sidekiq_health
      return @current_sidekiq_health if defined?(@current_sidekiq_health)
      @current_sidekiq_health = Rails.application.config.app_mode.self_hosted? ? SidekiqHealth.current : nil
    end

    def accessible_accounts
      Current.accessible_accounts
    end
    helper_method :accessible_accounts

    def finance_accounts
      Current.finance_accounts
    end
    helper_method :finance_accounts
end
