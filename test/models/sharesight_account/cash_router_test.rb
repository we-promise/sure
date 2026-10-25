require "test_helper"

class SharesightAccount::CashRouterTest < ActiveSupport::TestCase
  HOLDINGS = [
    { "id" => 1, "quantity" => 20.0, "value" => 2100.0, "instrument_price" => 105.0,
      "instrument" => { "code" => "VAS", "market_code" => "ASX", "currency_code" => "AUD" }, "instrument_currency" => { "code" => "AUD" } }
  ].freeze

  TRADES = [
    { "id" => 1, "transaction_type" => "BUY", "transaction_date" => "2026-09-01", "symbol" => "VAS", "market" => "ASX",
      "quantity" => 10, "price" => 100.0, "exchange_rate" => 1.0, "brokerage" => 0, "holding_id" => 1, "state" => "confirmed" },
    { "id" => 2, "transaction_type" => "BUY", "transaction_date" => "2026-09-10", "symbol" => "VAS", "market" => "ASX",
      "quantity" => 5, "price" => 100.0, "exchange_rate" => 1.0, "brokerage" => 0, "holding_id" => 1, "state" => "confirmed" },
    { "id" => 3, "transaction_type" => "BUY", "transaction_date" => "2026-09-10", "symbol" => "VAS", "market" => "ASX",
      "quantity" => 5, "price" => 120.0, "exchange_rate" => 1.0, "brokerage" => 0, "holding_id" => 1, "state" => "confirmed" }
  ].freeze

  PAYOUTS = [
    { "id" => 50, "symbol" => "VAS", "market" => "ASX", "paid_on" => "2026-09-20", "amount" => 30.0, "currency" => "AUD",
      "holding_id" => 1, "state" => "confirmed" }
  ].freeze

  # A$120 dividend, A$98 of it reinvested, so A$22 left over.
  REINVESTED = PAYOUTS.first.merge("amount" => 120.0, "drp_trade_attributes" => { "dividend_reinvested" => true, "quantity" => 1, "price" => 98.0 })

  setup do
    @family = families(:dylan_family)
    item = @family.sharesight_items.create!(name: "Sharesight", client_id: "client-id", client_secret: "client-secret")
    @account = @family.accounts.create!(name: "Shares", balance: 0, currency: "AUD", accountable: Investment.new)
    @bank = @family.accounts.create!(name: "Macquarie CMA", balance: 0, currency: "AUD", accountable: Depository.new)
    @sharesight_account = item.sharesight_accounts.create!(
      name: "Shares", sharesight_account_id: "42", currency: "AUD", current_balance: 2100, cash_balance: 0,
      raw_holdings_payload: HOLDINGS, raw_trades_payload: TRADES, raw_payouts_payload: PAYOUTS,
      cash_mode: "settlement", settlement_account: @bank
    )
    @sharesight_account.ensure_account_provider!(@account)
    Security.find_or_create_by!(ticker: "VAS", exchange_operating_mic: "XASX")
  end

  test "trades and dividends settle against the bank feed as confirmed transfers" do
    bank_fed!
    buy = bank_transaction(1000, "2026-09-03", "CMC Markets buy")
    deposit = bank_transaction(-30, "2026-09-21", "VAS dividend")

    process

    leg = offset("trade_1")
    assert_equal [ BigDecimal("-1000"), "Transfer from Macquarie CMA" ], [ leg.amount, leg.name ]
    assert_linked leg, buy
    assert_equal "investment_contribution", buy.entryable.reload.kind

    dividend_leg = offset("payout_50")
    assert_equal BigDecimal("30"), dividend_leg.amount
    assert_linked dividend_leg, deposit
    assert_equal "funds_movement", deposit.entryable.reload.kind
  end

  test "the investment account holds shares only" do
    bank_fed!

    process

    assert_equal BigDecimal("0"), @account.entries.where(entryable_type: %w[Transaction Trade]).sum(:amount)
    @account.reload
    assert_equal [ BigDecimal("2100"), BigDecimal("0") ], [ @account.balance, @account.cash_balance ]
  end

  test "a trade worth a fraction of a cent still matches the bank in whole cents" do
    bank_fed!
    fractional = TRADES.map { |t| t["id"] == 1 ? t.merge("price" => 100.0004) : t }
    @sharesight_account.update!(raw_trades_payload: fractional)
    buy = bank_transaction(1000, "2026-09-03", "CMC Markets buy")

    process

    leg = offset("trade_1")
    assert_equal BigDecimal("-1000"), leg.amount
    assert_linked leg, buy
  end

  test "a day's trades settled as one amount are matched together" do
    bank_fed!
    settlement = bank_transaction(1100, "2026-09-12", "CMC Markets net settlement")

    process

    day = offset("day_2026-09-10_AUD")
    assert_equal BigDecimal("-1100"), day.amount
    assert_linked day, settlement
    assert_nil offset("trade_2", required: false)
    assert_nil offset("trade_3", required: false)
  end

  test "a settlement missing from the bank feed keeps the shares-only offset and is reported once overdue" do
    bank_fed!

    notices = process[:notices]

    assert_nil offset("trade_1").entryable.transfer
    assert_includes notices.map { |notice| notice[:message] }.join("\n"), "debit in Macquarie CMA for Buy 10"
  end

  test "earlier matches stay put when a look-alike turns up" do
    bank_fed!
    first = bank_transaction(1000, "2026-09-03", "CMC Markets buy")
    process
    bank_transaction(1000, "2026-09-02", "Something else")

    process

    assert_linked offset("trade_1"), first
  end

  test "a manual settlement account gets the other side booked for it" do
    process

    counterpart = @bank.entries.find_by!(external_id: "sharesight_counterpart_#{@sharesight_account.id}_trade_1")
    assert_equal [ BigDecimal("1000"), Date.new(2026, 9, 1) ], [ counterpart.amount, counterpart.date ]
    assert_linked offset("trade_1"), counterpart
    assert_equal BigDecimal("-30"), @bank.entries.find_by!(external_id: "sharesight_counterpart_#{@sharesight_account.id}_payout_50").amount
  end

  test "a reinvested dividend's leftover is linked when the bank feed shows it" do
    bank_fed!
    @sharesight_account.update!(raw_payouts_payload: [ REINVESTED ])
    leftover = bank_transaction(-22, "2026-09-21", "VAS dividend balance")

    process

    leg = offset("payout_50")
    assert_equal [ BigDecimal("22"), "Transfer to Macquarie CMA" ], [ leg.amount, leg.name ]
    assert_linked leg, leftover
  end

  test "a leftover the bank never shows isn't flagged as overdue" do
    bank_fed!
    @sharesight_account.update!(raw_payouts_payload: [ REINVESTED ])

    notices = process[:notices].map { |notice| notice[:message] }

    assert_equal "Settled outside Sure", offset("payout_50").name
    assert notices.none? { |message| message.include?("Dividend from VAS") }
  end

  test "a leftover isn't booked into a manual account" do
    @sharesight_account.update!(raw_payouts_payload: [ REINVESTED ])

    process

    assert_nil @bank.entries.find_by(external_id: "sharesight_counterpart_#{@sharesight_account.id}_payout_50")
    assert_equal "Settled outside Sure", offset("payout_50").name
  end

  test "untracked cash is offset without a counterpart anywhere" do
    @sharesight_account.update!(cash_mode: "untracked", settlement_account: nil)

    process

    leg = offset("trade_1")
    assert_equal [ BigDecimal("-1000"), "Settled outside Sure" ], [ leg.amount, leg.name ]
    assert_nil leg.entryable.transfer
    assert_empty @bank.entries
  end

  test "before the settlement start date the broker held the cash" do
    bank_fed!
    @sharesight_account.update!(settlement_starts_on: Date.new(2026, 9, 5))

    process

    assert_nil offset("trade_1", required: false)
    assert offset("trade_2")
  end

  test "dividends paid to another account are matched there" do
    bank_fed!
    other = @family.accounts.create!(name: "CommBank", balance: 0, currency: "AUD", accountable: Depository.new)
    deposit = other.entries.create!(name: "VAS dividend", date: Date.new(2026, 9, 20), amount: -30, currency: "AUD", entryable: Transaction.new)
    @sharesight_account.update!(cash_mode: "broker", settlement_account: nil, dividend_mode: "other_account", dividend_account: other)

    process

    assert_nil offset("trade_1", required: false)
    assert_linked offset("payout_50"), deposit
    assert_equal BigDecimal("-30"), @account.entries.find_by!(external_id: "sharesight_payout_50").amount
  end

  test "skipped dividends aren't imported and reinvested ones cost nothing" do
    reinvested = PAYOUTS.first.merge("drp_trade_attributes" => { "dividend_reinvested" => true, "quantity" => 1, "price" => 30.0 })
    @sharesight_account.update!(cash_mode: "broker", settlement_account: nil, dividend_mode: "skip", raw_payouts_payload: [ reinvested ])

    process

    assert_nil @account.entries.find_by(external_id: "sharesight_payout_50")
    assert_equal BigDecimal("0"), @account.entries.find_by!(external_id: "sharesight_drp_50").amount
  end

  test "switching back to the broker removes the offsets and frees the bank transactions" do
    bank_fed!
    buy = bank_transaction(1000, "2026-09-03", "CMC Markets buy")
    process
    @sharesight_account.update!(cash_mode: "broker", settlement_account: nil)

    process

    assert_empty @account.entries.where("external_id LIKE 'sharesight_offset_%'")
    assert_nil buy.entryable.reload.transfer
    assert_equal "standard", buy.entryable.kind
  end

  test "a pair the user unlinked stays unlinked" do
    bank_fed!
    buy = bank_transaction(1000, "2026-09-03", "CMC Markets buy")
    process
    offset("trade_1").entryable.transfer.reject!

    process

    assert_nil offset("trade_1").entryable.reload.transfer
    assert_nil buy.entryable.reload.transfer
  end

  private

    def process
      SharesightAccount::Processor.new(@sharesight_account.reload).process
    end

    # Pretend the settlement account comes from a bank feed.
    def bank_fed!
      Account.any_instance.stubs(:linked?).returns(true)
    end

    def bank_transaction(amount, date, name)
      @bank.entries.create!(name: name, date: Date.parse(date), amount: amount, currency: "AUD", entryable: Transaction.new)
    end

    def offset(key, required: true)
      scope = @account.entries.where(external_id: "sharesight_offset_#{key}")
      required ? scope.first! : scope.first
    end

    def assert_linked(leg, other)
      transfer = leg.entryable.reload.transfer
      assert transfer&.confirmed?, "#{leg.external_id} isn't a confirmed transfer"
      assert_includes [ transfer.inflow_transaction_id, transfer.outflow_transaction_id ], other.entryable_id
    end
end
