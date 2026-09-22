require "test_helper"

class AkahuAccount::PortfolioSplitterTest < ActiveSupport::TestCase
  # Payload shapes below mirror what Akahu actually returns for each
  # institution, so the split rules are pinned to real data rather than
  # assumptions.

  test "splits a multi-fund managed portfolio into one account per fund" do
    accounts = AkahuAccount::PortfolioSplitter.new(kernel_payload).split

    assert_equal 2, accounts.size

    first = accounts.first.with_indifferent_access
    assert_equal "acc_kernel::143705", first[:_id]
    assert_equal "Global 100", first[:name]
    assert_equal 103_157.91, first[:balance][:current]
    assert_equal "NZD", first[:balance][:currency]
    assert_equal "acc_kernel", first[:meta][:akahu_parent_account]
    assert_equal [ "Global 100" ], first[:meta][:portfolio].map { |f| f[:name] }
    assert_equal "INVESTMENT", first[:type]
    # Connection is carried through so the account is named
    # "<institution> - <fund>", matching how Simplicity accounts already appear.
    assert_equal "Kernel Wealth", first[:connection][:name]
  end

  test "does not split an account that already represents a single fund" do
    simplicity = {
      "_id" => "acc_simplicity",
      "name" => "Igor's Kiwisaver",
      "meta" => { "portfolio" => [ { "name" => "Growth", "value" => 87_744.93, "fund_id" => "730001" } ] }
    }

    refute AkahuAccount::PortfolioSplitter.new(simplicity).split?
    assert_empty AkahuAccount::PortfolioSplitter.new(simplicity).split
  end

  test "does not split exchange-listed positions" do
    # Sharesies and Sharesight report real tickers. Listed securities belong as
    # holdings against one brokerage account, not as separate accounts.
    listed = {
      "_id" => "acc_sharesight",
      "name" => "Sharesight",
      "meta" => { "portfolio" => [
        { "name" => "Spark New Zealand", "value" => 565.78, "shares" => 300, "symbol" => "SPK", "fund_id" => 28_184_589 },
        { "name" => "Mainfreight", "value" => 1200.0, "shares" => 20, "symbol" => "MFT", "fund_id" => 28_184_590 }
      ] }
    }

    refute AkahuAccount::PortfolioSplitter.new(listed).split?
  end

  test "ignores accounts with no portfolio" do
    refute AkahuAccount::PortfolioSplitter.new({ "_id" => "acc_x", "name" => "Savings" }).split?
  end

  test "falls back to the fund name when no fund id is supplied" do
    payload = kernel_payload
    payload["meta"]["portfolio"].each { |f| f.delete("fund_id") }

    ids = AkahuAccount::PortfolioSplitter.new(payload).split.map { |a| a["_id"] }

    assert_equal [ "acc_kernel::Global-100", "acc_kernel::High-Growth" ], ids
  end

  test "synthetic ids are recognisable so they are never sent to the API" do
    account = AkahuAccount.new(account_id: AkahuAccount::PortfolioSplitter.new(kernel_payload).split.first["_id"])

    assert account.synthetic?
    refute AkahuAccount.new(account_id: "acc_kernel").synthetic?
  end

  private

    def kernel_payload
      {
        "_id" => "acc_kernel",
        "name" => "Igor's Portfolio",
        "type" => "INVESTMENT",
        "status" => "ACTIVE",
        "balance" => { "current" => 173_899.89, "currency" => "NZD" },
        "connection" => { "name" => "Kernel Wealth" },
        "meta" => { "portfolio" => [
          { "name" => "Global 100", "value" => 103_157.91, "shares" => 914_568, "fund_id" => "143705", "currency" => "NZD" },
          { "name" => "High Growth", "value" => 70_741.98, "shares" => 906_797, "fund_id" => "157210", "currency" => "NZD" }
        ] }
      }
    end
end
