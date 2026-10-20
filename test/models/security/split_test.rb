require "test_helper"

class Security::SplitTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @security = Security.create!(ticker: "SPLT", name: "Split Test")
    @ex_date = Date.new(2025, 6, 10)
  end

  test "a split needs positive terms that are not one-for-one" do
    [ [ 0, 1 ], [ 2, 0 ], [ -2, 1 ], [ 3, 3 ] ].each do |numerator, denominator|
      split = @security.splits.new(ex_date: @ex_date, numerator: numerator, denominator: denominator, source: "manual")

      assert_not split.valid?, "#{numerator}:#{denominator} should be refused"
    end

    assert @security.splits.new(ex_date: @ex_date, numerator: 1, denominator: 10, source: "manual").valid?
  end

  test "one split per security per ex-date" do
    @security.splits.create!(ex_date: @ex_date, numerator: 2, denominator: 1, source: "manual")

    assert_not @security.splits.new(ex_date: @ex_date, numerator: 3, denominator: 1, source: "manual").valid?
    assert Security.create!(ticker: "OTHR", name: "Other").splits.new(ex_date: @ex_date, numerator: 3, denominator: 1, source: "manual").valid?
  end

  test "the database refuses a zero term that bypasses the model" do
    split = @security.splits.create!(ex_date: @ex_date, numerator: 2, denominator: 1, source: "manual")

    assert_raises(ActiveRecord::StatementInvalid) { split.update_columns(denominator: 0) }
  end

  test "the ratio is exact" do
    split = @security.splits.new(ex_date: @ex_date, numerator: 1, denominator: 3, source: "manual")

    assert_equal Rational(1, 3), split.ratio
  end

  test "deleting the security deletes its splits" do
    @security.splits.create!(ex_date: @ex_date, numerator: 2, denominator: 1, source: "manual")

    assert_difference "Security::Split.count", -1 do
      @security.destroy
    end
  end

  test "the split factor between two dates takes the splits after the first and on or before the second" do
    @security.splits.create!(ex_date: @ex_date, numerator: 2, denominator: 1, source: "manual")
    @security.splits.create!(ex_date: @ex_date + 30, numerator: 3, denominator: 1, source: "manual")

    assert_equal 1, @security.split_factor_between(@ex_date - 10, @ex_date - 1)
    assert_equal 2, @security.split_factor_between(@ex_date - 1, @ex_date)
    assert_equal 1, @security.split_factor_between(@ex_date, @ex_date + 29)
    assert_equal 6, @security.split_factor_between(@ex_date - 1, @ex_date + 30)
  end
  test "an unknown source is refused" do
    assert_not @security.splits.new(ex_date: @ex_date, numerator: 2, denominator: 1, source: "yahoo").valid?
  end

  test "manual and snaptrade are accepted" do
    %w[manual snaptrade].each do |source|
      assert @security.splits.new(ex_date: @ex_date, numerator: 2, denominator: 1, source: source).valid?, source
    end
  end

  test "a manual write replaces a provider row on the same ex-date" do
    record(2, 1, "snaptrade")

    split = record(3, 1, "manual")

    assert_equal 1, @security.splits.count
    assert_equal [ 3, 1, "manual" ], split.reload.values_at(:numerator, :denominator, :source)
  end

  test "a provider write never replaces a manual row, and logs when its terms differ" do
    manual = record(2, 1, "manual")

    returned = nil
    assert_difference -> { DebugLogEntry.count }, 1 do
      returned = record(3, 1, "snaptrade")
    end

    assert_equal manual, returned
    assert_equal [ 2, 1, "manual" ], manual.reload.values_at(:numerator, :denominator, :source)
    log = DebugLogEntry.order(:created_at).last
    assert_equal "snaptrade", log.provider_key
    assert_equal [ "3:1", "2:1", @ex_date.iso8601 ], log.metadata.values_at("provider_ratio", "manual_ratio", "ex_date")
  end

  test "a provider write that matches a manual row logs nothing" do
    record(2, 1, "manual")

    assert_no_difference -> { DebugLogEntry.count } do
      record(4, 2, "snaptrade")
    end
    assert_equal "manual", @security.splits.sole.source
  end

  test "a provider write replaces another provider row" do
    record(2, 1, "snaptrade")

    record(3, 1, "snaptrade")

    assert_equal [ 3, 1 ], @security.splits.sole.values_at(:numerator, :denominator)
  end

  test "recording a split enqueues a rematerialize job for every account holding the security, in every family, and none for an unrelated account" do
    holder = holding_account(families(:dylan_family))
    trader = trading_account(families(:empty))
    unrelated = families(:empty).accounts.create!(name: "Unrelated", balance: 0, cash_balance: 0, currency: "USD", accountable: Investment.new)

    record(2, 1, "manual")

    assert_equal [ holder, trader ].map(&:id).sort, enqueued_account_ids.sort
    assert_not_includes enqueued_account_ids, unrelated.id
  end

  test "an unchanged write enqueues nothing" do
    holding_account(families(:dylan_family))
    record(2, 1, "manual")
    clear_enqueued_jobs

    record(2, 1, "manual")
    record(3, 1, "snaptrade")

    assert_empty enqueued_account_ids
  end

  test "removing a split enqueues the same jobs" do
    holder = holding_account(families(:dylan_family))
    split = record(2, 1, "manual")
    clear_enqueued_jobs

    assert_difference "Security::Split.count", -1 do
      split.remove!
    end
    assert_equal [ holder.id ], enqueued_account_ids
  end

  test "moving a split's ex-date enqueues them once, not twice" do
    holder = holding_account(families(:dylan_family))
    split = record(2, 1, "manual")
    clear_enqueued_jobs

    split.revise!(ex_date: @ex_date + 5, numerator: 2, denominator: 1, source: "manual")

    assert_equal @ex_date + 5, split.reload.ex_date
    assert_equal [ holder.id ], enqueued_account_ids
  end

  test "a duplicate's split moves to the canonical security" do
    canonical = Security.create!(ticker: "CANO", name: "Canonical")
    split = record(2, 1, "snaptrade")

    Security::Split.move!(from: @security, to: canonical)

    assert_equal canonical.id, split.reload.security_id
  end

  test "on a collision manual wins" do
    canonical = Security.create!(ticker: "CANO", name: "Canonical")
    canonical.splits.create!(ex_date: @ex_date, numerator: 3, denominator: 1, source: "snaptrade")
    record(2, 1, "manual")

    Security::Split.move!(from: @security, to: canonical)

    assert_equal [ 2, 1, "manual" ], canonical.splits.sole.values_at(:numerator, :denominator, :source)
    assert_empty @security.splits.reload
  end

  test "on a collision between equals the canonical row stays" do
    canonical = Security.create!(ticker: "CANO", name: "Canonical")
    canonical.splits.create!(ex_date: @ex_date, numerator: 3, denominator: 1, source: "manual")
    record(2, 1, "manual")

    Security::Split.move!(from: @security, to: canonical)

    assert_equal [ 3, 1 ], canonical.splits.sole.values_at(:numerator, :denominator)
    assert_empty @security.splits.reload
  end

  private
    def record(numerator, denominator, source)
      Security::Split.record!(security: @security, ex_date: @ex_date, numerator: numerator, denominator: denominator, source: source)
    end

    def enqueued_account_ids
      enqueued_jobs.select { |job| job[:job] == SecuritySplitRematerializeJob }
        .map { |job| ActiveJob::Arguments.deserialize(job[:args]).first.id }
    end

    def holding_account(family)
      account = family.accounts.create!(name: "Holder", balance: 0, cash_balance: 0, currency: "USD", accountable: Investment.new)
      account.holdings.create!(security: @security, date: @ex_date - 1, qty: 1, price: 10, amount: 10, currency: "USD")
      account
    end

    def trading_account(family)
      account = family.accounts.create!(name: "Trader", balance: 0, cash_balance: 0, currency: "USD", accountable: Investment.new)
      account.entries.create!(name: "Buy", date: @ex_date - 1, amount: 10, currency: "USD",
                              entryable: Trade.new(security: @security, qty: 1, price: 10, currency: "USD", investment_activity_label: "Buy"))
      account
    end
end
