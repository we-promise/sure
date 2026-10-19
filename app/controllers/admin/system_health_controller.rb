# frozen_string_literal: true

module Admin
  class SystemHealthController < Admin::BaseController
    before_action :require_hosted_push, only: :send_test_push
    before_action :require_hosted_usage, only: :hosted_usage
    skip_before_action :sync_family, only: :hosted_usage

    # Bypass the per-request memo / cross-request cache that the layout
    # banner uses. An operator landing on this page (often right after
    # restarting the worker) wants to confirm the current state, not a
    # snapshot up to `SidekiqHealth::CACHE_TTL` old. Also makes the page
    # work in managed mode, where `current_sidekiq_health` is nil.
    def show
      @hosted_usage_available = hosted_usage_available?
      tabs = %w[background_jobs ai]
      tabs << "hosted_usage" if @hosted_usage_available
      @active_tab = params[:tab].presence_in(tabs) || "background_jobs"
      if Apns::Client.hosted?
        @push_notification_test = PushNotificationTest.new(Current.user)
        @push_disabled_reason = @push_notification_test.disabled_reason
        @latest_push_test = @push_notification_test.latest
        @push_test_results = @latest_push_test ? @push_notification_test.results(@latest_push_test) : []
      end
      SidekiqHealth.expire_cache!
      @health = SidekiqHealth.new
    end

    # Each live probe can take up to AiHealth::Probe.timeout, so the page
    # loads this into its AI tab through a lazy frame instead of waiting on
    # the probes before it renders.
    def ai_status
      @ai_health = AiHealth.new(force_probes: params[:refresh_ai_health] == "1")
      @worker_ai_health_results = WorkerAiHealth.recent
      render layout: false
    end

    # Keep the bounded database snapshot out of the initial health-page load.
    def hosted_usage
      @hosted_usage = HostedUsage.new
      render layout: false
    end

    # Queues an asynchronous worker-side verification (see
    # WorkerAiHealthCheckJob) and returns immediately -- the result appears
    # in the AI status tab once whichever worker process dequeues it
    # finishes, typically within a few seconds.
    def verify_worker_ai
      WorkerAiHealth.request_check!
      redirect_to admin_system_health_path(tab: "ai", locale: locale_from_param), notice: t(".queued")
    end

    def send_test_push
      result = PushNotificationTest.new(Current.user).request!
      flash[result == :queued ? :notice : :alert] = t("admin.system_health.push_notifications.messages.#{result}")
      redirect_to admin_system_health_path(tab: "background_jobs", anchor: "push-notifications"), status: :see_other
    end

    private
      def require_hosted_usage
        head :not_found unless hosted_usage_available?
      end

      def hosted_usage_available?
        # Rails may derive request.host from X-Forwarded-Host. Require the
        # original Host header too, so another deployment cannot expose this
        # report through a forwarded-host override.
        original_host = request.get_header("HTTP_HOST").to_s
        original_host.match?(/\A#{Regexp.escape(request.host)}(?::[0-9]+)?\z/) &&
          HostedUsage.available?(request_host: request.host)
      end

      def require_hosted_push
        head :not_found unless Apns::Client.hosted?
      end
  end
end
