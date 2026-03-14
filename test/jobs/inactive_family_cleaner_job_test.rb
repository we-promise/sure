require "test_helper"

class InactiveFamilyCleanerJobTest < ActiveJob::TestCase
  setup do
    @inactive_family = families(:inactive_trial)
    @inactive_user = users(:inactive_trial_user)
    Rails.application.config.stubs(:app_mode).returns("managed".inquiry)
  end

  test "skips in self-hosted mode" do
    Rails.application.config.stubs(:app_mode).returns("self_hosted".inquiry)

    assert_no_difference "Family.count" do
      InactiveFamilyCleanerJob.perform_now
    end
  end

  test "destroys empty post-trial family with no accounts" do
    assert_equal 0, @inactive_family.accounts.count

    assert_difference "Family.count", -1 do
      InactiveFamilyCleanerJob.perform_now
    end

    assert_not Family.exists?(@inactive_family.id)
  end

  test "does not create archive for family with no accounts" do
    assert_no_difference "ArchivedExport.count" do
      InactiveFamilyCleanerJob.perform_now
    end
  end

  test "destroys family with accounts but few transactions" do
    account = @inactive_family.accounts.create!(
      name: "Test", currency: "USD", balance: 0, accountable: Depository.new, status: :active
    )
    # Add only 5 transactions (below threshold of 12)
    5.times do |i|
      account.entries.create!(
        name: "Txn #{i}", date: 50.days.ago + i.days, amount: 10, currency: "USD",
        entryable: Transaction.new
      )
    end

    assert_difference "Family.count", -1 do
      InactiveFamilyCleanerJob.perform_now
    end

    assert_no_difference "ArchivedExport.count" do
      # Already destroyed above, just verifying no archive was created
    end
  end

  test "archives then destroys family with 12+ recent transactions" do
    account = @inactive_family.accounts.create!(
      name: "Test", currency: "USD", balance: 0, accountable: Depository.new, status: :active
    )

    trial_end = @inactive_family.subscription.trial_ends_at
    # Create 15 transactions, some within last 14 days of trial
    15.times do |i|
      account.entries.create!(
        name: "Txn #{i}", date: trial_end - i.days, amount: 10, currency: "USD",
        entryable: Transaction.new
      )
    end

    assert_difference "ArchivedExport.count", 1 do
      assert_difference "Family.count", -1 do
        InactiveFamilyCleanerJob.perform_now
      end
    end

    archive = ArchivedExport.last
    assert_equal "inactive@example.com", archive.email
    assert_equal "Inactive Trial Family", archive.family_name
    assert archive.export_file.attached?
    assert archive.download_token_digest.present?
    assert archive.expires_at > 89.days.from_now
  end

  test "preserves families with active subscriptions" do
    dylan_family = families(:dylan_family)
    assert dylan_family.subscription.active?

    InactiveFamilyCleanerJob.perform_now

    assert Family.exists?(dylan_family.id)
  end

  test "preserves families still within grace period" do
    @inactive_family.subscription.update!(trial_ends_at: 5.days.ago)

    initial_count = Family.count
    InactiveFamilyCleanerJob.perform_now

    assert Family.exists?(@inactive_family.id)
  end

  test "destroys families with no subscription created long ago" do
    old_family = Family.create!(name: "Abandoned", created_at: 90.days.ago)
    old_family.users.create!(
      first_name: "Old", last_name: "User", email: "old-abandoned@example.com",
      password: "password123", role: :admin, onboarded_at: 90.days.ago,
      ai_enabled: true, show_sidebar: true, show_ai_sidebar: true, ui_layout: :dashboard
    )
    # No subscription created

    assert_nil old_family.subscription

    InactiveFamilyCleanerJob.perform_now

    assert_not Family.exists?(old_family.id)
  end

  test "preserves recently created families with no subscription" do
    recent_family = Family.create!(name: "New Family")
    recent_family.users.create!(
      first_name: "New", last_name: "User", email: "newuser-recent@example.com",
      password: "password123", role: :admin, onboarded_at: 1.day.ago,
      ai_enabled: true, show_sidebar: true, show_ai_sidebar: true, ui_layout: :dashboard
    )

    InactiveFamilyCleanerJob.perform_now

    assert Family.exists?(recent_family.id)

    # Cleanup
    recent_family.destroy
  end

  test "dry run does not destroy or archive" do
    account = @inactive_family.accounts.create!(
      name: "Test", currency: "USD", balance: 0, accountable: Depository.new, status: :active
    )
    trial_end = @inactive_family.subscription.trial_ends_at
    15.times do |i|
      account.entries.create!(
        name: "Txn #{i}", date: trial_end - i.days, amount: 10, currency: "USD",
        entryable: Transaction.new
      )
    end

    assert_no_difference [ "Family.count", "ArchivedExport.count" ] do
      InactiveFamilyCleanerJob.perform_now(dry_run: true)
    end

    assert Family.exists?(@inactive_family.id)
  end
end
