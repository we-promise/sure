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
        assert_nil ApiKey.find_by(display_key: ApiKey::DEMO_MONITORING_KEY)
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
end
