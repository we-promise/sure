# frozen_string_literal: true

require "test_helper"

RakeTaskTestHelper.load_task("simplefin:pending_restore", "simplefin_pending_cleanup")

class SimplefinPendingCleanupTest < ActiveSupport::TestCase
  setup do
    RakeTaskTestHelper.prepare("simplefin:pending_restore", "simplefin:pending_cleanup", "simplefin:pending_list")
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

  test "pending list reads the pending flag the way Transaction#pending? does" do
    pending = create_entry("simplefin", true, 20)
    unknown = create_entry("simplefin", "maybe", 21)
    off = create_entry("simplefin", "off", 22)
    no = create_entry("simplefin", "no", 23) # not one of Rails' false values, so pending
    posted = create_entry("simplefin", false, 24)
    absent = create_entry("simplefin", nil, 25, flagless: true)

    output, = capture_io { Rake::Task["simplefin:pending_list"].invoke }

    assert_includes output, "ID=#{pending.id}"
    assert_includes output, "ID=#{unknown.id}"
    assert_includes output, "ID=#{no.id}"
    [ off, posted, absent ].each { |entry| assert_not_includes output, "ID=#{entry.id}" }
  end

  test "pending cleanup matches the posted side with Transaction#pending? semantics" do
    unknown = create_entry("simplefin", "maybe", 30)
    posted_off = create_entry("simplefin", "off", 30, date: 9.days.ago.to_date)
    false_flag = create_entry("simplefin", "off", 31)
    create_entry("simplefin", false, 31, date: 9.days.ago.to_date)
    still_pending = create_entry("simplefin", true, 32)
    posted_unknown = create_entry("simplefin", "maybe", 32, date: 9.days.ago.to_date)
    posted_no = create_entry("simplefin", "no", 32, date: 8.days.ago.to_date)
    genuine = create_entry("simplefin", true, 33)
    posted_absent = create_entry("simplefin", nil, 33, date: 9.days.ago.to_date, flagless: true)

    output, = capture_io { Rake::Task["simplefin:pending_cleanup"].invoke }

    assert_includes output, "Pending: ID=#{unknown.id}"
    assert_includes output, "Posted:  ID=#{posted_off.id}"
    assert_includes output, "Pending: ID=#{genuine.id}"
    assert_includes output, "Posted:  ID=#{posted_absent.id}"
    assert_not_includes output, "Pending: ID=#{false_flag.id}", "a Rails false value is not pending"
    assert_not_includes output, "Pending: ID=#{still_pending.id}", "an unknown flag is pending, so it is not a posted match"
    assert_not_includes output, "Posted:  ID=#{posted_unknown.id}"
    assert_not_includes output, "Posted:  ID=#{posted_no.id}"
    assert_includes output, "Summary: 2 duplicate pending transactions found"
    assert_equal 9, @account.entries.count, "dry run must not delete anything"
  end

  private
    def create_entry(provider, pending, amount, date: 10.days.ago.to_date, flagless: false)
      extra = flagless ? { provider => {} } : { provider => { "pending" => pending } }
      @account.entries.create!(
        name: "#{provider}-#{amount}-#{date}", date: date, amount: amount, currency: "USD",
        source: provider, entryable: Transaction.new(extra: extra)
      )
    end

    def create_excluded_entry(provider, pending, amount)
      @account.entries.create!(
        name: "#{provider}-#{amount}", date: 10.days.ago.to_date, amount: amount, currency: "USD",
        excluded: true,
        entryable: Transaction.new(extra: { provider => { "pending" => pending } })
      )
    end
end
