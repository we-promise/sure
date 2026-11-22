require "test_helper"

class Security::MergerTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @account = accounts(:investment)
    @placeholder = Security.create!(ticker: "MRGX", offline: true, offline_reason: "resolution_pending")
    @listed = Security.create!(ticker: "MRGX", exchange_operating_mic: "XNAS", name: "Merge Co")
  end

  test "moves holdings, trades, prices, splits and tags onto the target and deletes the source" do
    only_on_placeholder = create_holding(@placeholder, date: 3.days.ago.to_date, qty: 2)
    newer_on_placeholder = create_holding(@placeholder, date: 2.days.ago.to_date, qty: 5)
    older_on_listed = create_holding(@listed, date: 2.days.ago.to_date, qty: 3)
    older_on_placeholder = create_holding(@placeholder, date: 1.day.ago.to_date, qty: 7)
    newer_on_listed = create_holding(@listed, date: 1.day.ago.to_date, qty: 4)
    older_on_listed.update_columns(updated_at: 1.hour.ago)
    older_on_placeholder.update_columns(updated_at: 1.hour.ago)

    trade_entry = create_trade(@placeholder, account: @account, qty: 1, date: 3.days.ago.to_date, price: 10)

    moved_price = Security::Price.create!(security: @placeholder, date: 3.days.ago.to_date, price: 10, currency: "USD")
    Security::Price.create!(security: @placeholder, date: 2.days.ago.to_date, price: 11, currency: "USD")
    kept_price = Security::Price.create!(security: @listed, date: 2.days.ago.to_date, price: 12, currency: "USD")

    moved_split = Security::Split.create!(security: @placeholder, ex_date: 10.days.ago.to_date, numerator: 2, denominator: 1, source: "manual")
    Security::Split.create!(security: @placeholder, ex_date: 20.days.ago.to_date, numerator: 3, denominator: 1, source: "manual")
    kept_split = Security::Split.create!(security: @listed, ex_date: 20.days.ago.to_date, numerator: 4, denominator: 1, source: "manual")

    Tagging.create!(tag: tags(:one), taggable: @placeholder)
    Tagging.create!(tag: tags(:one), taggable: @listed)
    Tagging.create!(tag: tags(:two), taggable: @placeholder)

    Account.any_instance.expects(:sync_later).once

    assert_equal @listed, Security::Merger.new(from: @placeholder, into: @listed).merge!

    assert_not Security.exists?(@placeholder.id)

    assert_equal @listed.id, only_on_placeholder.reload.security_id
    assert_equal @listed.id, newer_on_placeholder.reload.security_id
    assert_not Holding.exists?(older_on_listed.id)
    assert_not Holding.exists?(older_on_placeholder.id)
    assert_equal @listed.id, newer_on_listed.reload.security_id
    assert_equal [ 2, 5, 4 ], @account.holdings.where(security: @listed).order(:date).pluck(:qty).map(&:to_i)

    assert_equal @listed.id, trade_entry.reload.trade.security_id

    assert_equal [ moved_price.id, kept_price.id ].sort, @listed.prices.ids.sort
    assert_equal [ moved_split.id, kept_split.id ].sort, @listed.splits.ids.sort
    assert_equal [ tags(:one).id, tags(:two).id ].sort, Tagging.where(taggable: @listed).pluck(:tag_id).sort
  end

  test "repoints provider securities and drops remaps onto the security itself" do
    other = Security.create!(ticker: "MRGY", exchange_operating_mic: "XNAS")
    remapped_to_listed = create_holding(@listed, date: Date.current, qty: 1, provider_security: @placeholder, security_locked: true)
    remapped_elsewhere = create_holding(other, date: Date.current, qty: 1, provider_security: @placeholder, security_locked: true)

    Security::Merger.new(from: @placeholder, into: @listed).merge!

    remapped_to_listed.reload
    assert_nil remapped_to_listed.provider_security_id
    assert_not remapped_to_listed.security_locked

    remapped_elsewhere.reload
    assert_equal @listed.id, remapped_elsewhere.provider_security_id
    assert remapped_elsewhere.security_locked
  end

  test "combines opening lots and repoints lot origins" do
    HoldingLot.create!(account: @account, security: @placeholder, origin_security: @placeholder, qty: 2, currency: "USD")
    listed_lot = HoldingLot.create!(account: @account, security: @listed, origin_security: @listed, qty: 3, currency: "USD")

    Security::Merger.new(from: @placeholder, into: @listed).merge!

    lots = HoldingLot.where(account: @account, security: @listed)
    assert_equal [ listed_lot.id ], lots.ids
    assert_equal 5, listed_lot.reload.qty
    assert_not HoldingLot.where(origin_security_id: @placeholder.id).exists?
  end

  test "leaves both rows alone when the condition no longer holds under the lock" do
    @placeholder.update!(offline: false, offline_reason: nil)

    Security::Merger.new(from: @placeholder, into: @listed).merge!(condition: ->(source) { source.offline? })

    assert Security.exists?(@placeholder.id)
  end

  test "is a no-op when the source is the target" do
    Account.any_instance.expects(:sync_later).never

    assert_equal @listed, Security::Merger.new(from: @listed, into: @listed).merge!
    assert Security.exists?(@listed.id)
  end

  test "returns the target when the source was already merged" do
    stale = Security.find(@placeholder.id)
    Security::Merger.new(from: @placeholder, into: @listed).merge!

    assert_equal @listed, Security::Merger.new(from: stale, into: @listed).merge!
  end

  test "counts what it moved and can leave the syncs to its caller" do
    create_holding(@placeholder, date: 2.days.ago.to_date, qty: 1)
    collided = create_holding(@placeholder, date: 1.day.ago.to_date, qty: 1)
    create_holding(@listed, date: 1.day.ago.to_date, qty: 2).update_columns(updated_at: 1.hour.ago)
    create_trade(@placeholder, account: @account, qty: 1, date: 3.days.ago.to_date, price: 10)
    HoldingLot.create!(account: @account, security: @placeholder, qty: 2, currency: "USD")
    other = Security.create!(ticker: "MRGO", exchange_operating_mic: "XNAS")
    HoldingLot.create!(account: @account, security: other, origin_security: @placeholder, qty: 1, currency: "USD")
    Account.any_instance.expects(:sync_later).never

    merger = Security::Merger.new(from: @placeholder, into: @listed)
    merger.merge!(sync: false)

    assert_equal({ holdings_moved: 2, holdings_removed: 1, trades: 1, lots: 1, references: 1 }, merger.counts)
    assert_equal [ @account.id ], merger.account_ids
    assert_equal @listed.id, collided.reload.security_id
  end

  # Another row of the same ticker and MIC still exists while a group is
  # merged, so the keeper's name is written without re-validating the ticker.
  test "a keeper with no name takes the duplicate's while another duplicate remains" do
    ActiveRecord::Base.connection.execute("DROP INDEX index_securities_on_ticker_and_exchange_operating_mic_unique")
    keeper = Security.new(ticker: "MRGZ", exchange_operating_mic: "XNAS").tap { |s| s.save!(validate: false) }
    named = Security.new(ticker: "MRGZ", exchange_operating_mic: "XNAS", name: "Merge Z").tap { |s| s.save!(validate: false) }
    Security.new(ticker: "mrgz", exchange_operating_mic: "XNAS").save!(validate: false)

    Security::Merger.new(from: named, into: keeper).merge!

    assert_not Security.exists?(named.id)
    assert_equal "Merge Z", keeper.reload.name
  end

  test "a group merges whole or not at all, and leaves the syncs to its caller" do
    second = Security.create!(ticker: "MRGX", exchange_operating_mic: "XNYS")
    first_holding = create_holding(@placeholder, date: 1.day.ago.to_date, qty: 1)
    create_holding(second, date: 2.days.ago.to_date, qty: 1)
    account_ids = Set.new

    Account.any_instance.expects(:sync_later).never
    counts = Security::Merger.merge_group!([ @placeholder, second ], into: @listed, account_ids: account_ids)
    assert_equal 2, counts[:holdings_moved]
    assert_equal Set[@account.id], account_ids

    third = Security.create!(ticker: "MRGW", offline: true)
    fourth = Security.create!(ticker: "MRGV", offline: true)
    third_holding = create_holding(third, date: 2.days.ago.to_date, qty: 1)
    Security::Merger.any_instance.stubs(:move_taggings!).returns(nil).then.raises(RuntimeError, "boom")

    rolled_back_ids = Set.new

    assert_raises(RuntimeError) { Security::Merger.merge_group!([ third, fourth ], into: @listed, account_ids: rolled_back_ids) }
    assert Security.exists?(third.id), "the first merge is rolled back"
    assert_equal third.id, third_holding.reload.security_id
    assert_equal @listed.id, first_holding.reload.security_id
    assert_empty rolled_back_ids, "a rolled-back group adds no accounts to sync"
  end

  test "a group keeps the most recently written holding when two sources collide" do
    Account.any_instance.stubs(:sync_later)

    [ %i[older newer], %i[newer older] ].each do |order|
      sources = {
        older: Security.create!(ticker: "MRGA", offline: true),
        newer: Security.create!(ticker: "MRGB", offline: true)
      }
      create_holding(sources[:older], date: 1.day.ago.to_date, qty: 1).update_columns(updated_at: 2.days.ago)
      create_holding(sources[:newer], date: 1.day.ago.to_date, qty: 2).update_columns(updated_at: 1.hour.ago)

      Security::Merger.merge_group!(sources.values_at(*order), into: @listed, account_ids: Set.new)

      assert_equal [ 2 ], @account.holdings.where(security: @listed).pluck(:qty).map(&:to_i), "merged #{order.join(' then ')}"
      @account.holdings.where(security: @listed).delete_all
    end
  end

  test "moved and repointed holdings keep their original write time" do
    other = Security.create!(ticker: "MRGY", exchange_operating_mic: "XNAS")
    written_at = 3.days.ago.change(usec: 0)
    moved = create_holding(@placeholder, date: 2.days.ago.to_date, qty: 1)
    remapped_to_listed = create_holding(@listed, date: Date.current, qty: 1, provider_security: @placeholder, security_locked: true)
    remapped_elsewhere = create_holding(other, date: Date.current, qty: 1, provider_security: @placeholder, security_locked: true)
    [ moved, remapped_to_listed, remapped_elsewhere ].each { |holding| holding.update_columns(updated_at: written_at) }

    Security::Merger.new(from: @placeholder, into: @listed).merge!

    assert_equal @listed.id, moved.reload.security_id
    assert_nil remapped_to_listed.reload.provider_security_id
    assert_equal @listed.id, remapped_elsewhere.reload.provider_security_id
    assert_equal [ written_at ] * 3, [ moved, remapped_to_listed, remapped_elsewhere ].map(&:updated_at)
  end

  test "keeps every family's tags, and one tagging where the target already has the tag" do
    other_tag = families(:empty).tags.create!(name: "Another household's scheme")
    Tagging.create!(tag: tags(:one), taggable: @listed)
    Tagging.create!(tag: tags(:one), taggable: @placeholder)
    Tagging.create!(tag: other_tag, taggable: @placeholder)

    Security::Merger.new(from: @placeholder, into: @listed).merge!

    assert_equal [ tags(:one).id, other_tag.id ].sort, Tagging.where(taggable: @listed).pluck(:tag_id).sort
    assert_equal [ other_tag ], @listed.tags_for(families(:empty)).to_a
  end

  private
    def create_holding(security, date:, qty:, **attributes)
      @account.holdings.create!(security: security, date: date, qty: qty, price: 10, amount: qty * 10, currency: "USD", **attributes)
    end
end
