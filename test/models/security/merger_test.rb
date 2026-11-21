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

  private
    def create_holding(security, date:, qty:, **attributes)
      @account.holdings.create!(security: security, date: date, qty: qty, price: 10, amount: qty * 10, currency: "USD", **attributes)
    end
end
