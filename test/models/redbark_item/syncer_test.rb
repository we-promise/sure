# frozen_string_literal: true

require "test_helper"

class RedbarkItem::SyncerTest < ActiveSupport::TestCase
  setup do
    @redbark_item = redbark_items(:one)
    @redbark_account = redbark_accounts(:savings_account)
    @family = @redbark_item.family

    account = @family.accounts.create!(
      name: "Mortgage", balance: 400_000, currency: "AUD",
      accountable: Loan.new(rate_type: "variable", interest_rate: 6.25)
    )
    @redbark_account.ensure_account_provider!(account)

    @syncer = RedbarkItem::Syncer.new(@redbark_item)
  end

  # A sync reads the bank in one phase and acts on what it read in the next.
  # RedbarkAccount::LoanDetailsProcessor decides whether a stored snapshot
  # belongs to the sync now running by comparing the stamp the import wrote
  # against the date the processing was given. If those two come from separate
  # readings of the clock, a sync that fetches at 23:59 and processes at 00:00
  # discards the snapshot it has just stored, and the rate change in it is lost
  # until the bank happens to move the rate again.
  #
  # THE SYNC IS MADE TO CROSS MIDNIGHT, and that is the whole design of the
  # test. Comparing the two values alone proves nothing: two separate readings
  # of the clock return the same date on all but one run in 86,400, so a test
  # that merely compared them would pass against the very defect it names --
  # which is what the first version of this test did. The
  # clock is moved past midnight while the import is in flight, so a second
  # reading taken afterwards can only disagree with the first.
  test "the account details stamp and the processing date come from one clock" do
    stamped = nil
    dated = nil
    before_midnight = Time.zone.local(2026, 9, 21, 23, 59, 59)

    travel_to before_midnight do
      @redbark_item.expects(:import_latest_redbark_data).with { |**kwargs|
        stamped = kwargs[:fetched_at]
        # The fetch takes two seconds and the day turns while it runs.
        travel_to Time.zone.local(2026, 9, 22, 0, 0, 1)
        true
      }.returns({})

      @redbark_item.expects(:process_accounts).with { |**kwargs|
        dated = kwargs[:as_of]
        true
      }.returns([])

      @syncer.perform_sync(mock_sync)
    end

    assert_kind_of Date, dated, "the processing phase was not given a date at all"
    assert_not_nil stamped, "the import phase was not given a clock to stamp with"
    assert_equal Date.new(2026, 9, 21), stamped.to_date,
                 "the stamp was not taken before midnight, so the test is not exercising the crossing"
    assert_equal stamped.to_date, dated,
                 "the import stamped one date and the processing dated its findings by another"
  end

  private

    def mock_sync
      sync = mock("sync")
      sync.stubs(:respond_to?).with(:status_text).returns(true)
      sync.stubs(:respond_to?).with(:sync_stats).returns(true)
      sync.stubs(:sync_stats).returns({})
      sync.stubs(:created_at).returns(Time.current)
      sync.stubs(:window_start_date).returns(nil)
      sync.stubs(:window_end_date).returns(nil)
      sync.stubs(:update!)
      sync
    end
end
