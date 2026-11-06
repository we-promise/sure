require "test_helper"
require "rake"

# The tasks that merge duplicate securities destroy each duplicate, and a
# security's splits go with it (dependent: :destroy). They move holdings,
# trades and prices to the security that stays; its splits have to move too.
class SecuritiesRakeTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("securities:deduplicate")
    %w[securities:deduplicate data_migration:migrate_duplicate_securities].each { |name| Rake::Task[name].reenable }
    @ex_date = Date.new(2025, 6, 10)
  end

  test "a duplicate without a MIC keeps its splits on the canonical security" do
    canonical = Security.create!(ticker: "SPLR", exchange_operating_mic: "XNAS", name: "Canonical")
    duplicate = Security.create!(ticker: "SPLR", exchange_operating_mic: nil, name: "No MIC")
    duplicate.splits.create!(ex_date: @ex_date, numerator: 2, denominator: 1, source: "manual")

    capture_io { Rake::Task["securities:deduplicate"].invoke }

    assert_not Security.exists?(duplicate.id)
    assert_equal [ [ @ex_date, 2, 1 ] ], canonical.splits.pluck(:ex_date, :numerator, :denominator)
  end

  # Both of these group on ticker and MIC, which the unique index on securities
  # now rules out. Dropping it inside the test's transaction (Postgres DDL is
  # transactional) recreates the older data these tasks were written for.
  test "a same-ticker, same-MIC duplicate keeps its splits on the canonical security" do
    canonical, duplicate = same_ticker_pair

    capture_io { Rake::Task["securities:deduplicate"].invoke }

    assert_not Security.exists?(duplicate.id)
    assert_equal [ [ @ex_date, 2, 1 ] ], canonical.splits.pluck(:ex_date, :numerator, :denominator)
  end

  test "the duplicate-securities migration keeps a duplicate's splits on the keeper" do
    keeper, duplicate = same_ticker_pair

    capture_io { Rake::Task["data_migration:migrate_duplicate_securities"].invoke }

    assert_not Security.exists?(duplicate.id)
    assert_equal [ [ @ex_date, 2, 1 ] ], keeper.splits.pluck(:ex_date, :numerator, :denominator)
  end

  private
    def same_ticker_pair
      ActiveRecord::Base.connection.remove_index :securities, name: "index_securities_on_ticker_and_exchange_operating_mic_unique"
      canonical = Security.create!(ticker: "SPLD", exchange_operating_mic: "XNAS", name: "First", created_at: 2.days.ago)
      duplicate = Security.new(ticker: "SPLD", exchange_operating_mic: "XNAS", name: "Second")
      duplicate.save!(validate: false)
      duplicate.splits.create!(ex_date: @ex_date, numerator: 2, denominator: 1, source: "manual")
      [ canonical, duplicate ]
    end
end
