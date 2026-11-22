# frozen_string_literal: true

require "test_helper"
require "rake"

RakeTaskTestHelper.load_task("securities:deduplicate", "securities")

class SecuritiesDeduplicateTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    RakeTaskTestHelper.prepare("securities:deduplicate")
    @account = accounts(:investment)
    @canonical = Security.create!(ticker: "DUPX", exchange_operating_mic: "XNAS", name: "Dup X")
    @duplicate = Security.create!(ticker: "DUPX", exchange_operating_mic: nil, name: "Dup X without MIC")
  end

  # A family's tags on a duplicate are moved like its holdings, trades and
  # prices, rather than destroyed with it.
  test "merging a duplicate without a MIC keeps its tags on the canonical security" do
    canonical = securities(:aapl)
    duplicate = Security.create!(ticker: "AAPL", exchange_operating_mic: nil, name: "Apple duplicate")
    duplicate.taggings.create!(tag: tags(:one))

    capture_io { Rake::Task["securities:deduplicate"].invoke }

    assert_not Security.exists?(duplicate.id)
    assert_equal [ tags(:one) ], canonical.tags_for(families(:dylan_family)).to_a
  end

  test "a duplicate's lots move to the canonical security, and other lots' origin with them" do
    buy = create_trade(@duplicate, account: @account, qty: 2, date: 3.days.ago.to_date, price: 10)
    derived = HoldingLot.create!(account: @account, security: @duplicate, source_entry: buy, qty: 2, unit_cost: 10, currency: "USD", acquired_on: 3.days.ago.to_date)
    HoldingLot.create!(account: @account, security: @duplicate, qty: 4, currency: "USD")
    canonical_opening = HoldingLot.create!(account: @account, security: @canonical, qty: 6, currency: "USD")
    other = Security.create!(ticker: "REMAPPED", name: "Remapped")
    remapped = HoldingLot.create!(account: @account, security: other, origin_security: @duplicate, qty: 1, currency: "USD")

    capture_io { Rake::Task["securities:deduplicate"].invoke }

    assert_equal @canonical.id, derived.reload.security_id, "the derived lot keeps its row"
    assert_equal [ [ canonical_opening.id, 10 ] ], HoldingLot.opening.where(account: @account, security: @canonical).pluck(:id, :qty)
    assert_equal @canonical.id, remapped.reload.origin_security_id
  end

  test "a colliding holding keeps the more recently written row" do
    date = Date.current
    Holding.create!(account: @account, security: @canonical, date: date, qty: 1, price: 10, amount: 10, currency: "USD")
    newer = travel_to(1.minute.from_now) { Holding.create!(account: @account, security: @duplicate, date: date, qty: 3, price: 10, amount: 30, currency: "USD") }

    capture_io { Rake::Task["securities:deduplicate"].invoke }

    assert_not Security.exists?(@duplicate.id)
    assert_equal [ [ newer.id, 3 ] ], Holding.where(account: @account, security: @canonical, date: date).pluck(:id, :qty)
  end

  test "the accounts that held the duplicate are queued for sync" do
    Holding.create!(account: @account, security: @duplicate, date: Date.current, qty: 1, price: 10, amount: 10, currency: "USD")

    assert_difference -> { @account.syncs.count }, 1 do
      capture_io { Rake::Task["securities:deduplicate"].invoke }
    end
  end

  # A sync queued between merges can be absorbed by one already running
  # before the later merges land, so each account is synced once, at the end.
  test "an account touched by two merges is synced once, after both" do
    other_canonical = Security.create!(ticker: "DUPZ", exchange_operating_mic: "XNAS", name: "Dup Z")
    other_duplicate = Security.create!(ticker: "DUPZ", exchange_operating_mic: nil, name: "Dup Z without MIC")
    Holding.create!(account: @account, security: @duplicate, date: Date.current, qty: 1, price: 10, amount: 10, currency: "USD")
    Holding.create!(account: @account, security: other_duplicate, date: Date.current, qty: 1, price: 10, amount: 10, currency: "USD")
    duplicate_ids = [ @duplicate.id, other_duplicate.id ]

    Account.any_instance.expects(:sync_later).once.with { Security.where(id: duplicate_ids).none? }

    capture_io { Rake::Task["securities:deduplicate"].invoke }

    assert_equal 1, Holding.where(account: @account, security: other_canonical).count
  end

  test "a sync dispatch that fails for one account still syncs the others" do
    other_account = accounts(:depository)
    Holding.create!(account: @account, security: @duplicate, date: Date.current, qty: 1, price: 10, amount: 10, currency: "USD")
    Holding.create!(account: other_account, security: @duplicate, date: Date.current, qty: 1, price: 10, amount: 10, currency: "USD")
    Account.any_instance.expects(:sync_later).twice.raises(StandardError, "queue down").then.returns(nil)
    Rails.logger.expects(:error).with(regexp_matches(/queue down/)).once

    capture_io { Rake::Task["securities:deduplicate"].invoke }

    assert_not Security.exists?(@duplicate.id)
  end

  test "a dry run changes nothing and reports the lots and references it would move" do
    HoldingLot.create!(account: @account, security: @duplicate, qty: 4, currency: "USD")
    other = Security.create!(ticker: "REFX", name: "Referencing")
    HoldingLot.create!(account: @account, security: other, origin_security: @duplicate, qty: 1, currency: "USD")
    Holding.create!(account: @account, security: other, provider_security: @duplicate, security_locked: true, date: Date.current, qty: 1, price: 10, amount: 10, currency: "USD")

    out, = capture_io { Rake::Task["securities:deduplicate"].invoke("true") }

    assert Security.exists?(@duplicate.id)
    assert_equal 1, HoldingLot.where(security: @duplicate).count
    assert_match(/- 1 lots\n    - 2 references/, out)
  end

  test "the task reports what it moved and the rule for colliding holdings" do
    date = Date.current
    Holding.create!(account: @account, security: @canonical, date: date, qty: 1, price: 10, amount: 10, currency: "USD").update_columns(updated_at: 1.hour.ago)
    Holding.create!(account: @account, security: @duplicate, date: date, qty: 3, price: 10, amount: 30, currency: "USD")
    Holding.create!(account: @account, security: @duplicate, date: date - 1.day, qty: 3, price: 10, amount: 30, currency: "USD")

    out, = capture_io { Rake::Task["securities:deduplicate"].invoke }

    assert_match "2 holdings moved, 1 colliding holdings removed (the more recently written row is kept)", out
  end

  test "a keeper with no name takes a same-ticker duplicate's" do
    ActiveRecord::Base.connection.execute("DROP INDEX index_securities_on_ticker_and_exchange_operating_mic_unique")
    @duplicate.destroy!
    @canonical.update_columns(name: nil)
    twin = travel_to(1.minute.from_now) { Security.new(ticker: "DUPX", exchange_operating_mic: "XNAS", name: "Dup X named").tap { |s| s.save!(validate: false) } }

    capture_io { Rake::Task["securities:deduplicate"].invoke }

    assert_not Security.exists?(twin.id)
    assert_equal "Dup X named", @canonical.reload.name
  end

  # Two rows with the same ticker and MIC cannot be written while the unique
  # index and validation stand; the index is dropped inside the test's
  # transaction and the row saved without validation.
  test "a duplicate with the same ticker and MIC has its lots moved too" do
    ActiveRecord::Base.connection.execute("DROP INDEX index_securities_on_ticker_and_exchange_operating_mic_unique")
    twin = Security.new(ticker: "DUPX", exchange_operating_mic: "XNAS", name: "Dup X twin").tap { |s| s.save!(validate: false) }
    @duplicate.destroy!
    buy = create_trade(twin, account: @account, qty: 2, date: 3.days.ago.to_date, price: 10)
    derived = HoldingLot.create!(account: @account, security: twin, source_entry: buy, qty: 2, unit_cost: 10, currency: "USD", acquired_on: 3.days.ago.to_date)

    capture_io { Rake::Task["securities:deduplicate"].invoke }

    assert_not Security.exists?(twin.id)
    assert_equal @canonical.id, derived.reload.security_id
  end
end
