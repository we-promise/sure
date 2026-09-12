# frozen_string_literal: true

module Admin
  class SystemHealthController < Admin::BaseController
    before_action :require_hosted_push, only: :send_test_push

    # Bypass the per-request memo / cross-request cache that the layout
    # banner uses. An operator landing on this page (often right after
    # restarting the worker) wants to confirm the current state, not a
    # snapshot up to `SidekiqHealth::CACHE_TTL` old. Also makes the page
    # work in managed mode, where `current_sidekiq_health` is nil.
    def show
      tabs = %w[background_jobs ai]
      @active_tab = params[:tab].presence_in(tabs) || "background_jobs"
      if Apns::Client.hosted? && @active_tab == "background_jobs"
        @push_notification_test = PushNotificationTest.new(Current.user)
        @push_disabled_reason = @push_notification_test.disabled_reason
        @latest_push_test = @push_notification_test.latest
        @push_test_results = @latest_push_test ? @push_notification_test.results(@latest_push_test) : []
      end
      SidekiqHealth.expire_cache!
      @health = SidekiqHealth.new
      ai_tab = params[:tab] == "ai"
      @ai_health = AiHealth.new(
        run_probes: ai_tab,
        force_probes: ai_tab && params[:refresh_ai_health] == "1"
      )
      @worker_ai_health_results = WorkerAiHealth.recent if ai_tab
    end

    # Queues an asynchronous worker-side verification (see
    # WorkerAiHealthCheckJob) and returns immediately -- the result appears
    # in the AI status tab once whichever worker process dequeues it
    # finishes, typically within a few seconds.
    def verify_worker_ai
      WorkerAiHealth.request_check!
      redirect_to admin_system_health_path(tab: "ai"), notice: t(".queued")
    end

    def send_test_push
      result = PushNotificationTest.new(Current.user).request!
      flash[result == :queued ? :notice : :alert] = t("admin.system_health.push_notifications.messages.#{result}")
      redirect_to admin_system_health_path(tab: "background_jobs", anchor: "push-notifications"), status: :see_other
    end

    private
      def require_hosted_push
        head :not_found unless Apns::Client.hosted?
      end
  end
end
