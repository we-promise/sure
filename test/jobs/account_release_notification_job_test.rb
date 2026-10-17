require "test_helper"

class AccountReleaseNotificationJobTest < ActiveJob::TestCase
  include ActionMailer::TestHelper

  setup do
    @family = families(:dylan_family)
    @admin = users(:family_admin)
    @member = users(:family_member)
    @family.update!(timezone: "UTC")
    @family.users.update_all(preferences: {})
    travel_to Time.utc(2026, 10, 5, 12)
  end

  test "mails a digest to a member who chose e-mail" do
    enable(@admin, channel: "email")
    term_deposit(available_on: Date.new(2026, 10, 10))

    assert_emails 1 do
      perform
    end

    mail = ActionMailer::Base.deliveries.last
    assert_equal [ @admin.email ], mail.to
    assert_match "Term deposit", mail.text_part.body.decoded
  end

  test "never mails the same reminder twice" do
    enable(@admin, channel: "both")
    term_deposit(available_on: Date.new(2026, 10, 10))

    assert_emails(1) { perform }
    assert_emails(0) { perform }
  end

  test "mails again when the reminder changes kind" do
    enable(@admin, channel: "email")
    term_deposit(available_on: Date.new(2026, 10, 10))
    perform

    travel_to Time.utc(2026, 10, 10, 12)

    assert_emails(1) { perform }
    assert_equal %w[released upcoming], AccountReleaseNotice.where(user: @admin).pluck(:kind).sort
  end

  test "a failed e-mail is tried again on the next run" do
    enable(@admin, channel: "email")
    term_deposit(available_on: Date.new(2026, 10, 10))

    AccountAvailabilityMailer.any_instance.stubs(:release_digest).raises(StandardError, "SMTP down")
    assert_emails(0) { perform }
    assert_empty AccountReleaseNotice.where(user: @admin)

    AccountAvailabilityMailer.any_instance.unstub(:release_digest)
    assert_emails(1) { perform }
  end

  test "uses each member's own lead time and accounts" do
    enable(@admin, channel: "email", lead_days: 3)
    enable(@member, channel: "email", lead_days: 30)
    term_deposit(available_on: Date.new(2026, 10, 20))

    # The admin's lead time has not started; the member does not follow the
    # admin's private deposit.
    assert_emails(0) { perform }
  end

  test "sends nothing to members who chose the feed or nothing" do
    enable(@admin, channel: "insight")
    enable(@member, channel: "off")
    term_deposit(available_on: Date.new(2026, 10, 6))

    assert_emails(0) { perform }
  end

  test "the cron run fans out to families with preview features only" do
    enable(@admin, channel: "email")

    assert_enqueued_with(job: AccountReleaseNotificationJob, args: [ { family_id: @family.id } ]) do
      AccountReleaseNotificationJob.perform_now
    end
  end

  private
    def perform
      AccountReleaseNotificationJob.perform_now(family_id: @family.id)
    end

    def enable(user, channel:, lead_days: 14)
      user.update!(preferences: {
        "preview_features_enabled" => true,
        "account_release_channel" => channel,
        "account_release_lead_days" => lead_days
      })
    end

    def term_deposit(available_on:)
      @family.accounts.create!(name: "Term deposit", balance: 5000, currency: "USD", owner: @admin,
                               accountable: Depository.new(subtype: "cd"), available_on: available_on)
    end
end
