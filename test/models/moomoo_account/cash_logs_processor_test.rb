require "test_helper"

class MoomooAccount::CashLogsProcessorTest < ActiveSupport::TestCase
  setup do
    @moomoo_account = moomoo_accounts(:main_account)
    @account = families(:dylan_family).accounts.create!(name: "moomoo SG", balance: 0, cash_balance: 0, currency: "SGD", accountable: Investment.new)
    @moomoo_account.ensure_account_provider!(@account)
    @moomoo_account.reload
  end

  test "imports cash movements in the currency of their balance, dated in Singapore time" do
    store(
      row("Bank Transfer Deposits", "+1,200.00", "Balance: 1,200.00 SGD", time: "03/02/2026 23:30:00"),
      row("Currency Exchange", "-1,200.00", "Balance: 0.00 SGD", time: "03/03/2026 10:00:00"),
      row("Currency Exchange", "+900.00", "Balance: 900.00 USD", time: "03/03/2026 10:00:00"),
      row("Cash Dividend", "+2.00", "Balance: 902.00 USD", symbol: "ACME"),
      row("Dividend Tax", "-0.60", "Balance: 901.40 USD", symbol: "ACME"),
      row("Stock Sell Fee", "-1.05", "Balance: 900.35 USD", symbol: "ACME"),
      row("Fund Dividend", "+3.10", "Balance: 3.10 SGD", symbol: "18000001", stock_name: "Example SGD Cash Fund"),
      row("Bank Transfer Withdrawals", "-100.00", "Balance: 800.35 USD")
    )

    assert_equal({ transactions: 8, skipped: 0 }, process)

    deposit = entry_named("Bank Transfer Deposits")
    assert_equal [ BigDecimal("-1200"), "SGD", Date.new(2026, 3, 2) ], [ deposit.amount, deposit.currency, deposit.date ]
    assert_equal [ "investment_contribution", "Contribution" ], [ deposit.entryable.kind, deposit.entryable.investment_activity_label ]

    exchange = @account.entries.where(name: "Currency Exchange").order(:amount).pluck(:amount, :currency)
    assert_equal [ [ BigDecimal("-900"), "USD" ], [ BigDecimal("1200"), "SGD" ] ], exchange

    assert_equal [ BigDecimal("-2"), "USD", "Dividend" ], entry_values("Cash Dividend ACME")
    assert_equal [ BigDecimal("0.6"), "USD", "Fee" ], entry_values("Dividend Tax ACME")
    assert_equal [ BigDecimal("1.05"), "USD", "Fee" ], entry_values("Stock Sell Fee ACME")
    assert_equal [ BigDecimal("-3.1"), "SGD", "Dividend" ], entry_values("Fund Dividend Example SGD Cash Fund")
    assert_equal [ BigDecimal("100"), "USD", "Withdrawal" ], entry_values("Bank Transfer Withdrawals")
  end

  test "skips trades and money market fund moves, which the fills and cash already cover" do
    store(
      row("Stock Buy Execution", "-500.00", "Balance: 0.00 USD", symbol: "ACME"),
      row("Fund Subscription", "-1,000.00", "Balance: 0.00 SGD", symbol: "18000001"),
      row("Fund Redemption", "+500.00", "Balance: 500.00 SGD", symbol: "18000001")
    )

    assert_equal({ transactions: 0, skipped: 3 }, process)
    assert_empty @account.entries.where(entryable_type: "Transaction")
    assert_not DebugLogEntry.where(provider_key: "moomoo").where("message LIKE ?", "%CashLogsProcessor%").exists?
  end

  test "logs rows it cannot read, and imports each row once" do
    store(
      row("Bank Transfer Deposits", "+50.00", "Balance: 50.00 SGD"),
      row("Something New", "+1.00", "Balance: 51.00 SGD"),
      row("Cash Dividend", "+1.00", "Balance: 52.00", symbol: "ACME")
    )

    assert_equal({ transactions: 1, skipped: 2 }, process)
    assert_equal({ transactions: 1, skipped: 2 }, process)
    assert_equal 1, @account.entries.where(entryable_type: "Transaction").count
    assert DebugLogEntry.where(provider_key: "moomoo").where("message LIKE ?", "%CashLogsProcessor%").exists?
  end

  private

    def process
      MoomooAccount::CashLogsProcessor.new(@moomoo_account.reload).process
    end

    def store(*rows)
      @moomoo_account.update!(raw_cash_logs_payload: rows)
    end

    def row(name, change, balance, time: "03/04/2026 15:30:00", symbol: "", stock_name: "")
      fields = { "transaction_name" => name, "created_time" => time, "cash_change" => change, "balance" => balance, "symbol" => symbol, "stock_name" => stock_name }
      fields.merge("digest" => Digest::SHA256.hexdigest(fields.values.join("|"))[0, 32])
    end

    def entry_named(name)
      @account.entries.find_by!(name: name)
    end

    def entry_values(name)
      entry = entry_named(name)
      [ entry.amount, entry.currency, entry.entryable.investment_activity_label ]
    end
end
