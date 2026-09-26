# frozen_string_literal: true

require "test_helper"

RakeTaskTestHelper.load_task("simplefin:pending_restore", "simplefin_pending_cleanup")

class SimplefinPendingCleanupTest < ActiveSupport::TestCase
  setup do
    RakeTaskTestHelper.prepare("simplefin:pending_restore")
    @family = families(:empty)
    @account = @family.accounts.create!(name: "Pending restore", balance: 0, currency: "USD", accountable: Depository.new)
    @previous_dry_run = ENV["DRY_RUN"]
    @previous_date_window = ENV["DATE_WINDOW"]
    ENV["DRY_RUN"] = "true"
    ENV["DATE_WINDOW"] = "8"
  end

  teardown do
    ENV["DRY_RUN"] = @previous_dry_run
    ENV["DATE_WINDOW"] = @previous_date_window
  end

  test "pending restore handles malformed pending values and leaves false or unrelated flags out" do
    malformed = create_excluded_entry("simplefin", "maybe", 10)
    false_flag = create_excluded_entry("simplefin", "off", 11)
    unrelated_provider = create_excluded_entry("lunchflow", true, 12)

    output, = capture_io { Rake::Task["simplefin:pending_restore"].invoke }

    assert_includes output, "ID=#{malformed.id}"
    assert_not_includes output, "ID=#{false_flag.id}"
    assert_not_includes output, "ID=#{unrelated_provider.id}"
    assert malformed.reload.excluded?, "dry run only reports rows; it must not mutate them"
  end

  private
    def create_excluded_entry(provider, pending, amount)
      @account.entries.create!(
        name: "#{provider}-#{amount}", date: 10.days.ago.to_date, amount: amount, currency: "USD",
        excluded: true,
        entryable: Transaction.new(extra: { provider => { "pending" => pending } })
      )
    end
end
