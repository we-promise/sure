require "test_helper"

class SyncJobTest < ActiveJob::TestCase
  test "sync is performed" do
    syncable = accounts(:depository)

    sync = syncable.syncs.create!(window_start_date: 2.days.ago.to_date)

    sync.expects(:perform).once

    SyncJob.perform_now(sync)
  end

  test "runs a cash-anchored account's sync in its family's time zone" do
    account = cash_anchored(accounts(:crypto))
    account.family.update!(timezone: "Pacific/Auckland")
    sync = account.syncs.create!
    zone = nil
    sync.define_singleton_method(:perform) { zone = Time.zone.name }

    SyncJob.perform_now(sync)

    assert_equal "Pacific/Auckland", zone
  end

  test "keeps the application zone for an account without a cash anchor" do
    account = accounts(:depository)
    account.family.update!(timezone: "Pacific/Auckland")
    sync = account.syncs.create!
    zone = nil
    sync.define_singleton_method(:perform) { zone = Time.zone.name }

    SyncJob.perform_now(sync)

    assert_equal Time.zone.name, zone
  end

  test "falls back to the application zone for an unknown family zone" do
    account = cash_anchored(accounts(:crypto))
    account.family.update_column(:timezone, "Not/AZone")
    sync = account.syncs.create!
    zone = nil
    sync.define_singleton_method(:perform) { zone = Time.zone.name }

    SyncJob.perform_now(sync)

    assert_equal Time.zone.name, zone
  end

  private
    def cash_anchored(account)
      account.entries.create!(date: Date.current, name: "Cash", amount: 0, currency: account.currency,
        entryable: Valuation.new(kind: :cash_anchor))
      account
    end
end
