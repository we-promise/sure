# frozen_string_literal: true

require "test_helper"

class Onchain::HistoryBudgetTest < ActiveSupport::TestCase
  test "defaults to a depth a public endpoint can serve" do
    assert_equal Onchain::HistoryBudget::DEFAULT_PAGES, Onchain::HistoryBudget.pages
    assert_equal Onchain::HistoryBudget::DEFAULT_PAGES * Onchain::HistoryBudget::PAGE_SIZE,
                 Onchain::HistoryBudget.transactions
  end

  test "a self-hoster can raise it" do
    with_env("50") { assert_equal 50, Onchain::HistoryBudget.pages }
  end

  test "nonsense values fall back or are clamped rather than disabling history" do
    with_env("0") { assert_equal Onchain::HistoryBudget::DEFAULT_PAGES, Onchain::HistoryBudget.pages }
    with_env("-5") { assert_equal Onchain::HistoryBudget::DEFAULT_PAGES, Onchain::HistoryBudget.pages }
    with_env("nope") { assert_equal Onchain::HistoryBudget::DEFAULT_PAGES, Onchain::HistoryBudget.pages }
    with_env("100000") { assert_equal Onchain::HistoryBudget::MAX_PAGES, Onchain::HistoryBudget.pages }
  end

  private
    def with_env(value)
      previous = ENV["ONCHAIN_HISTORY_MAX_PAGES"]
      ENV["ONCHAIN_HISTORY_MAX_PAGES"] = value
      yield
    ensure
      ENV["ONCHAIN_HISTORY_MAX_PAGES"] = previous
    end
end
