# frozen_string_literal: true

require "test_helper"

class Onchain::HistoryBudgetTest < ActiveSupport::TestCase
  test "defaults to a depth a public endpoint can serve" do
    assert_equal Onchain::HistoryBudget::DEFAULT_PAGES, Onchain::HistoryBudget.pages
    assert_equal Onchain::HistoryBudget::DEFAULT_TRANSACTIONS, Onchain::HistoryBudget.transactions
  end

  # One transaction is one request on a per-transaction source, so this budget
  # must stay an order of magnitude below the page budget's row count or a sync
  # takes minutes instead of seconds.
  test "the per-transaction budget is far smaller than the paginated row count" do
    assert_operator Onchain::HistoryBudget.transactions, :<,
                    Onchain::HistoryBudget.pages * Onchain::HistoryBudget::PAGE_SIZE / 5
  end

  test "one knob scales both budgets" do
    with_env("50") do
      assert_equal 50, Onchain::HistoryBudget.pages
      assert_equal 125, Onchain::HistoryBudget.transactions
    end

    with_env("1") do
      assert_equal 1, Onchain::HistoryBudget.pages
      assert_operator Onchain::HistoryBudget.transactions, :>=, 1
    end
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
