# frozen_string_literal: true

require "test_helper"
require "rake"

RakeTaskTestHelper.load_task("data_migration:migrate_duplicate_securities", "data_migration")

class MigrateDuplicateSecuritiesTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    RakeTaskTestHelper.prepare("data_migration:migrate_duplicate_securities")
    # Duplicates cannot be written while the unique index and validation
    # stand; the index is dropped inside the test's transaction and the row
    # saved without validation.
    ActiveRecord::Base.connection.execute("DROP INDEX index_securities_on_ticker_and_exchange_operating_mic_unique")
    @account = accounts(:investment)
    @keeper = Security.create!(ticker: "DUPY", exchange_operating_mic: "XNAS", name: "Dup Y")
    @duplicate = travel_to(1.minute.from_now) { Security.new(ticker: "dupy", exchange_operating_mic: "xnas", name: "Dup Y again").tap { |s| s.save!(validate: false) } }
  end

  test "a duplicate's lots and holdings move to the earliest security" do
    buy = create_trade(@duplicate, account: @account, qty: 2, date: 3.days.ago.to_date, price: 10)
    derived = HoldingLot.create!(account: @account, security: @duplicate, source_entry: buy, qty: 2, unit_cost: 10, currency: "USD", acquired_on: 3.days.ago.to_date)
    holding = Holding.create!(account: @account, security: @duplicate, date: Date.current, qty: 2, price: 10, amount: 20, currency: "USD")

    capture_io { Rake::Task["data_migration:migrate_duplicate_securities"].invoke }

    assert_not Security.exists?(@duplicate.id)
    assert_equal [ @keeper.id, @keeper.id ], [ derived.reload.security_id, holding.reload.security_id ]
  end

  test "a keeper with no name takes the duplicate's" do
    @keeper.update_columns(name: nil)

    capture_io { Rake::Task["data_migration:migrate_duplicate_securities"].invoke }

    assert_not Security.exists?(@duplicate.id)
    assert_equal "Dup Y again", @keeper.reload.name
  end

  test "an account touched by two groups is synced once, after both" do
    other_keeper = Security.create!(ticker: "DUPW", exchange_operating_mic: "XNAS", name: "Dup W")
    other_duplicate = travel_to(1.minute.from_now) { Security.new(ticker: "dupw", exchange_operating_mic: "xnas").tap { |s| s.save!(validate: false) } }
    Holding.create!(account: @account, security: @duplicate, date: Date.current, qty: 1, price: 10, amount: 10, currency: "USD")
    Holding.create!(account: @account, security: other_duplicate, date: Date.current, qty: 1, price: 10, amount: 10, currency: "USD")
    duplicate_ids = [ @duplicate.id, other_duplicate.id ]

    Account.any_instance.expects(:sync_later).once.with { Security.where(id: duplicate_ids).none? }

    capture_io { Rake::Task["data_migration:migrate_duplicate_securities"].invoke }

    assert_equal 1, Holding.where(account: @account, security: other_keeper).count
  end
end
