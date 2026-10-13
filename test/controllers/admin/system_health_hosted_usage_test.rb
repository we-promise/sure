require "test_helper"

class Admin::SystemHealthHostedUsageControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    host! "app.sure.am"
    @user = users(:sure_support_staff)
    @user.update!(locale: "en")
    sign_in @user
    stub_healthy_sidekiq
  end

  test "both exact hosted domains expose only a lazy report frame on the health page" do
    HostedUsage.expects(:new).never

    %w[app.sure.am demo.sure.am].each do |domain|
      host! domain
      sign_in @user
      ClimateControl.modify("APP_DOMAIN" => domain) do
        %w[background_jobs ai hosted_usage].each do |tab|
          get admin_system_health_path(tab: tab)

          assert_response :success
          assert_select "button[role='tab'][data-id='hosted_usage']", text: "Hosted usage"
          assert_select "button[role='tab'][aria-selected='true'][data-id='#{tab}']"
          assert_select "turbo-frame#hosted_usage[loading='lazy'][src='#{hosted_usage_admin_system_health_path}']"
          assert_select "[data-testid='hosted-usage-report']", count: 0
        end
      end
    end
  end

  test "unapproved domains hide the tab and reject the direct endpoint before loading data" do
    HostedUsage.expects(:new).never

    [ nil, "localhost", "sure.onrender.com", "sub.app.sure.am", "app.sure.am.example.com", "https://app.sure.am", "demo.sure.am" ].each do |configured_domain|
      ClimateControl.modify("APP_DOMAIN" => configured_domain) do
        get admin_system_health_path(tab: "hosted_usage")
        assert_response :success
        assert_select "button[role='tab'][data-id='hosted_usage']", count: 0
        assert_select "turbo-frame#hosted_usage", count: 0
        assert_select "button[role='tab'][aria-selected='true'][data-id='background_jobs']"

        get hosted_usage_admin_system_health_path
        assert_response :not_found
      end
    end
  end

  test "an onrender request cannot access a report configured for an allowed domain" do
    host! "sure.onrender.com"
    sign_in @user
    HostedUsage.expects(:new).never

    ClimateControl.modify("APP_DOMAIN" => "app.sure.am") do
      get admin_system_health_path(tab: "hosted_usage")
      assert_response :success
      assert_select "button[role='tab'][data-id='hosted_usage']", count: 0

      get hosted_usage_admin_system_health_path
      assert_response :not_found
    end
  end

  test "the report inherits super admin and authentication requirements" do
    HostedUsage.expects(:new).never

    ClimateControl.modify("APP_DOMAIN" => "app.sure.am") do
      sign_in users(:family_admin)
      get hosted_usage_admin_system_health_path
      assert_redirected_to root_path

      reset!
      host! "app.sure.am"
      get hosted_usage_admin_system_health_path
      assert_redirected_to new_session_path
    end
  end

  test "forwarded host cannot expose hosted usage on an onrender host" do
    host! "sure-app.onrender.com"
    sign_in @user
    HostedUsage.expects(:new).never

    ClimateControl.modify("APP_DOMAIN" => "app.sure.am") do
      headers = { "X-Forwarded-Host" => "app.sure.am" }
      get admin_system_health_path(tab: "hosted_usage"), headers: headers
      assert_response :success
      assert_select "button[role='tab'][data-id='hosted_usage']", count: 0

      get hosted_usage_admin_system_health_path, headers: headers
      assert_response :not_found
    end
  end

  test "the exact hosted hostname accepts an explicit numeric port" do
    host! "app.sure.am:443"
    sign_in @user

    ClimateControl.modify("APP_DOMAIN" => "app.sure.am") do
      get hosted_usage_admin_system_health_path
    end

    assert_response :success
    assert_select "turbo-frame#hosted_usage"
  end

  test "report renders trial sessions cleanup supporters and the relocated expiring trial summary" do
    subscriptions(:trialing).update!(created_at: 2.days.ago, trial_ends_at: 3.days.from_now)
    subscriptions(:active).update!(stripe_id: "sub_supporter")
    families(:dylan_family).update!(stripe_customer_id: "cus_supporter")

    ClimateControl.modify("APP_DOMAIN" => "app.sure.am") do
      get hosted_usage_admin_system_health_path
    end

    assert_response :success
    assert_select "turbo-frame#hosted_usage"
    assert_select "[data-testid='hosted-usage-trials_expiring_soon_count'] dd", text: "1"
    assert_select "[data-testid='hosted-usage-active_supporter_households_count'] dd", text: "1"
    assert_select "[data-testid='hosted-usage-trials']" do
      assert_select "td", text: families(:empty).id
      assert_select "th", text: "Retained sign-in sessions"
      assert_select "th", text: "Retained sessions created in last 30 days"
      assert_select "td", text: "Trialing"
    end
    assert_select "[role='region'][aria-label='Recent trial households']"
    assert_select "[role='region'][aria-label='Cleanup eligibility']"
    assert_select "[role='region'][aria-label='Local supporter status']"
    assert_match "not currently online users or visits", response.body
    assert_match "Signing out deletes a record", response.body
    assert_match "Member accounts are not verified unique people", response.body
    assert_match "Recent logins do not prevent a match", response.body
    assert_match "90 days is archive retention", response.body
    assert_match "do not verify payments received", response.body
    assert_select "form, button, a[data-turbo-method]", count: 0
    assert_no_match(/#{Regexp.escape(@user.email)}|#{Regexp.escape(families(:empty).name)}/, response.body)
  end

  test "report GET makes no database writes and cannot enqueue auto sync or contact providers" do
    Admin::SystemHealthController.any_instance.stubs(:family_needs_auto_sync?).returns(true)
    Admin::SystemHealthController.any_instance.expects(:sync_family).never
    Provider::Registry.expects(:get_provider).never

    queries = []
    ClimateControl.modify("APP_DOMAIN" => "app.sure.am") do
      assert_no_enqueued_jobs do
        queries = capture_sql_queries { get hosted_usage_admin_system_health_path }
      end
    end

    assert_response :success
    assert_empty queries.grep(/\A(?:INSERT|UPDATE|DELETE)\b/i)
  end

  test "report renders empty states without inventing missing activity" do
    report = OpenStruct.new(
      as_of: Time.current, window_start: 30.days.ago, row_limit: 100,
      summary: { trial_households_count: 0, trials_expiring_soon_count: 0 },
      trials: [], cleanup_candidates: [],
      supporter_status_counts: Subscription.statuses.keys.index_with(0), cleanup_enabled?: true
    )
    HostedUsage.stubs(:new).returns(report)

    ClimateControl.modify("APP_DOMAIN" => "app.sure.am") do
      get hosted_usage_admin_system_health_path
    end

    assert_response :success
    assert_match "No trial households recorded in this window", response.body
    assert_match "No households match the cleanup scope", response.body
    assert_match "No Stripe-linked subscription rows", response.body
    assert_select "table", count: 0
  end

  test "synthetic demo rows are marked and disabled cleanup is clearly scoped" do
    subscriptions(:active).update!(stripe_id: "sub_demo_123", trial_ends_at: 2.days.from_now, created_at: 1.day.ago)
    Rails.application.config.stubs(:app_mode).returns("self_hosted".inquiry)

    ClimateControl.modify("APP_DOMAIN" => "app.sure.am") do
      get hosted_usage_admin_system_health_path
    end

    assert_response :success
    assert_match "Synthetic demo", response.body
    assert_match "Scheduled trial cleanup is disabled outside managed mode", response.body
  end

  test "the hosted frame preserves valid locale overrides and drops invalid ones" do
    ClimateControl.modify("APP_DOMAIN" => "app.sure.am") do
      get admin_system_health_path(tab: "hosted_usage", locale: "de")
      assert_select "button[role='tab'][aria-selected='true']", text: "Hosting-Nutzung"
      assert_select "turbo-frame#hosted_usage[src='#{hosted_usage_admin_system_health_path(locale: "de")}']"

      [ "xx", { "x" => "de" } ].each do |locale|
        get admin_system_health_path(tab: "hosted_usage", locale: locale)
        assert_response :success
        assert_select "turbo-frame#hosted_usage[src='#{hosted_usage_admin_system_health_path}']"
      end
    end
  end

  test "all hosted usage labels have translations in the supported health locales" do
    keys = I18n.t("admin.system_health.hosted_usage", locale: :en, fallback: false, raise: true)
    %i[en de fr pt-PT].each do |locale|
      assert_kind_of String, I18n.t("admin.system_health.show.tabs.hosted_usage", locale: locale, fallback: false, raise: true)
      assert_translations(keys, "admin.system_health.hosted_usage", locale)

      ClimateControl.modify("APP_DOMAIN" => "app.sure.am") do
        get hosted_usage_admin_system_health_path(locale: locale)
      end
      assert_response :success
      assert_select "h2", text: I18n.t("admin.system_health.hosted_usage.title", locale: locale)
      assert_no_match(/translation missing/i, response.body)
    end
  end

  private
    def assert_translations(keys, prefix, locale)
      keys.each do |key, value|
        path = "#{prefix}.#{key}"
        if value.is_a?(Hash)
          assert_translations(value, path, locale)
        else
          assert_kind_of String, I18n.t(path, locale: locale, fallback: false, raise: true, time: "2026-10-01", date: "2026-09-01", limit: 100)
        end
      end
    end

    def stub_healthy_sidekiq
      SidekiqHealth.any_instance.stubs(:healthy?).returns(true)
      SidekiqHealth.any_instance.stubs(:processes_count).returns(1)
      SidekiqHealth.any_instance.stubs(:last_heartbeat_at).returns(Time.current)
      SidekiqHealth.any_instance.stubs(:max_queue_latency).returns(0.0)
      SidekiqHealth.any_instance.stubs(:enqueued_count).returns(0)
      SidekiqHealth.any_instance.stubs(:retry_count).returns(0)
      SidekiqHealth.any_instance.stubs(:failed_count).returns(0)
      SidekiqHealth.any_instance.stubs(:processed_count).returns(42)
      SidekiqHealth.any_instance.stubs(:queue_breakdown).returns([])
    end
end
