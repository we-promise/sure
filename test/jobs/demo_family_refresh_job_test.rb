require "test_helper"

class DemoFamilyRefreshJobTest < ActiveJob::TestCase
  setup do
    @demo_email = "demo-user@example.com"
    Rails.application.stubs(:config_for).with(:demo).returns({ "email" => @demo_email })

    @demo_family = Family.create!(name: "Demo Family")
    @demo_user = @demo_family.users.create!(
      first_name: "Demo",
      last_name: "Admin",
      email: @demo_email,
      password: "password123",
      role: :admin,
      onboarded_at: Time.current,
      ai_enabled: true,
      show_sidebar: true,
      show_ai_sidebar: true,
      ui_layout: :dashboard
    )

    @super_admin = families(:dylan_family).users.create!(
      first_name: "Super",
      last_name: "Admin",
      email: "super-admin@example.com",
      password: "password123",
      role: :super_admin,
      onboarded_at: Time.current,
      ai_enabled: true,
      show_sidebar: true,
      show_ai_sidebar: true,
      ui_layout: :dashboard
    )
  end

  test "anonymizes old demo user email, enqueues deletion, regenerates data, and notifies super admins" do
    travel_to Time.utc(2026, 1, 1, 5, 0, 0) do
      Session.create!(user: @demo_user)
      Family.create!(name: "New Family Today", created_at: 6.hours.ago)
      Family.create!(name: "Old Family", created_at: 2.days.ago)
      @demo_user.api_keys.create!(
        name: "monitoring",
        key: ApiKey::DEMO_MONITORING_KEY,
        scopes: [ "read" ],
        source: "monitoring"
      )

      generator = mock
      generator.expects(:generate_default_data!).with(skip_clear: true, email: @demo_email) do
        assert ApiKey.find_by(display_key: ApiKey::DEMO_MONITORING_KEY)
      end
      Demo::Generator.expects(:new).returns(generator)

      assert_enqueued_with(job: DestroyJob, args: [ @demo_family ]) do
        assert_enqueued_jobs 2, only: ActionMailer::MailDeliveryJob do
          DemoFamilyRefreshJob.perform_now
        end
      end

      assert_not_equal @demo_email, @demo_user.reload.email
      assert_match(/\+deleting-/, @demo_user.email)
    end
  end

  test "reads demo email when config_for returns symbol keys" do
    Rails.application.stubs(:config_for).with(:demo).returns({ email: @demo_email })

    generator = mock
    generator.expects(:generate_default_data!).with(skip_clear: true, email: @demo_email)
    Demo::Generator.expects(:new).returns(generator)

    DemoFamilyRefreshJob.perform_now
  end

  test "self-hosted refresh is disabled by default" do
    Rails.configuration.stubs(:app_mode).returns("self_hosted".inquiry)
    Setting.demo_family_refresh_enabled = false
    Demo::Generator.expects(:new).never

    DemoFamilyRefreshJob.perform_now
    assert_equal @demo_email, @demo_user.reload.email
  end

  test "self-hosted refresh replaces only the explicitly selected demo family" do
    Rails.configuration.stubs(:app_mode).returns("self_hosted".inquiry)
    visitor = Family.create!(name: "Visitor")
    visitor_user = visitor.users.create!(first_name: "Visitor", last_name: "Owner", email: "visitor@example.com", password: "password123", role: :admin)
    Setting.demo_family_refresh_family_id = @demo_family.id.to_s
    Setting.demo_family_refresh_enabled = true

    generator = mock
    generator.expects(:generate_default_data!).with(skip_clear: true, email: @demo_email) do
      new_family = Family.create!(name: "Fresh Demo")
      new_family.users.create!(first_name: "New", last_name: "Demo", email: @demo_email, password: "password123", role: :admin)
    end
    Demo::Generator.expects(:new).returns(generator)

    assert_enqueued_with(job: DestroyJob, args: [ @demo_family ]) do
      DemoFamilyRefreshJob.perform_now
    end
    assert_equal visitor.id, visitor_user.reload.family_id
    assert_equal User.find_by!(email: @demo_email).family_id.to_s, Setting.demo_family_refresh_family_id
  ensure
    Setting.demo_family_refresh_enabled = false
    Setting.demo_family_refresh_family_id = nil
  end

  test "self-hosted refresh refuses a family mismatch or a monitoring key owned by another family" do
    Rails.configuration.stubs(:app_mode).returns("self_hosted".inquiry)
    Setting.demo_family_refresh_enabled = true
    Setting.demo_family_refresh_family_id = families(:dylan_family).id.to_s
    Demo::Generator.expects(:new).never
    DemoFamilyRefreshJob.perform_now
    assert_equal @demo_email, @demo_user.reload.email

    Setting.demo_family_refresh_family_id = @demo_family.id.to_s
    @super_admin.api_keys.create!(name: "monitoring", key: ApiKey::DEMO_MONITORING_KEY, scopes: [ "read" ], source: "monitoring")
    DemoFamilyRefreshJob.perform_now
    assert_equal @demo_email, @demo_user.reload.email
  ensure
    Setting.demo_family_refresh_enabled = false
    Setting.demo_family_refresh_family_id = nil
  end

  test "does not retry after a failed refresh" do
    assert_equal false, DemoFamilyRefreshJob.sidekiq_options_hash["retry"]
  end

  test "rolls back generated demo data when refresh fails" do
    failing_generator = Class.new do
      def generate_default_data!(skip_clear:, email:)
        Family.create!(name: "Partial Demo Family")
        raise ActiveRecord::RecordInvalid.new(Family.new)
      end
    end.new

    Demo::Generator.expects(:new).returns(failing_generator)

    assert_no_difference -> { Family.where(name: "Partial Demo Family").count } do
      assert_no_enqueued_jobs do
        assert_raises(ActiveRecord::RecordInvalid) do
          DemoFamilyRefreshJob.perform_now
        end
      end
    end

    assert_equal @demo_email, @demo_user.reload.email
  end

  test "skips refresh when another worker holds the advisory lock" do
    connection = ActiveRecord::Base.connection
    connection.expects(:select_value).with(regexp_matches(/pg_try_advisory_lock/)).returns(false)
    Rails.logger.expects(:warn).with("Skipped demo family refresh: advisory lock unavailable")
    Demo::Generator.expects(:new).never

    assert_no_enqueued_jobs do
      DemoFamilyRefreshJob.perform_now
    end
  end
end
