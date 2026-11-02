# frozen_string_literal: true

require "test_helper"

class CoinbaseAccount::ProcessorTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @family.update!(currency: "USD")
    @item = CoinbaseItem.create!(
      family: @family,
      name: "Coinbase",
      api_key: "k",
      api_secret: "s"
    )
    @coinbase_account = @item.coinbase_accounts.create!(
      name: "Bitcoin Wallet",
      account_id: "cb_btc_123",
      currency: "BTC",
      current_balance: 0.5,
      raw_payload: { "native_balance" => { "amount" => "25000", "currency" => "USD" } }
    )
    @account = Account.create!(
      family: @family,
      name: "Coinbase BTC",
      balance: 0,
      currency: "USD",
      accountable: Crypto.create!(subtype: "exchange")
    )
    AccountProvider.create!(account: @account, provider: @coinbase_account)
    @security = Security.create!(ticker: "CRYPTO:BTC", name: "BTC", exchange_operating_mic: "XCBS", offline: true)
    @coinbase_account.reload
  end

  # Regression for issue #2412: the bare `HoldingsProcessor` reference resolved
  # as CoinbaseAccount::Processor::HoldingsProcessor and raised an uninitialized
  # constant error that was swallowed, so holdings never refreshed.
  test "process invokes CoinbaseAccount::HoldingsProcessor" do
    CoinbaseAccount::HoldingsProcessor.any_instance.expects(:process).once

    CoinbaseAccount::Processor.new(@coinbase_account).process
  end

  test "updates linked crypto account balance from native_balance" do
    CoinbaseAccount::HoldingsProcessor.any_instance.stubs(:process).returns(nil)

    CoinbaseAccount::Processor.new(@coinbase_account).process

    @account.reload
    assert_equal 25_000.to_d, @account.balance
    assert_equal 0.to_d, @account.cash_balance
    assert_equal "USD", @account.currency
  end

  test "uses the exact Coinbase quantity for a spot-priced holding and account balance" do
    @coinbase_account.update!(current_balance: BigDecimal("0.00014884"), raw_payload: {})
    provider = mock("coinbase provider")
    provider.stubs(:get_spot_price).with("BTC-USD").returns({ "amount" => "66580" })
    CoinbaseItem.any_instance.stubs(:coinbase_provider).returns(provider)
    CoinbaseAccount::HoldingsProcessor.any_instance.stubs(:resolve_security).returns(@security)

    assert_difference -> { @account.holdings.count }, 1 do
      CoinbaseAccount::Processor.new(@coinbase_account).process
    end

    holding = @account.holdings.find_by!(security: @security, date: Date.current)
    assert_equal BigDecimal("0.00014884"), holding.qty
    assert_equal BigDecimal("9.91"), holding.amount
    assert_equal BigDecimal("9.91"), @account.reload.balance

    assert_no_difference -> { @account.holdings.count } do
      CoinbaseAccount::Processor.new(@coinbase_account).process
    end
    assert_equal BigDecimal("0.00014884"), holding.reload.qty
  end

  test "keeps the exact Coinbase quantity when native balance is available" do
    @coinbase_account.update!(
      current_balance: BigDecimal("0.00014884"),
      raw_payload: { "native_balance" => { "amount" => "9.91", "currency" => "EUR" } }
    )
    CoinbaseAccount::HoldingsProcessor.any_instance.stubs(:resolve_security).returns(@security)

    CoinbaseAccount::Processor.new(@coinbase_account).process

    holding = @account.holdings.find_by!(security: @security, date: Date.current)
    assert_equal BigDecimal("0.00014884"), holding.qty
    assert_equal BigDecimal("9.91"), holding.amount
    assert_equal BigDecimal("9.91"), @account.reload.balance
    assert_equal "EUR", @account.currency
  end

  test "keeps eighteen-decimal Coinbase quantities" do
    quantity = BigDecimal("0.000000000000000148")
    @coinbase_account.update!(current_balance: quantity, raw_payload: {})
    provider = mock("coinbase provider")
    provider.stubs(:get_spot_price).with("BTC-USD").returns({ "amount" => "66580" })
    CoinbaseItem.any_instance.stubs(:coinbase_provider).returns(provider)
    CoinbaseAccount::HoldingsProcessor.any_instance.stubs(:resolve_security).returns(@security)

    CoinbaseAccount::Processor.new(@coinbase_account).process

    holding = @account.holdings.find_by!(security: @security, date: Date.current)
    assert_equal quantity, holding.qty
  end

  test "imports a staking reward with its native value as income, not zero" do
    CoinbaseAccount::HoldingsProcessor.any_instance.stubs(:process).returns(nil)
    @coinbase_account.update!(raw_transactions_payload: {
      "transactions" => [
        coinbase_txn(id: "txn_reward_1", type: "staking_reward", btc_amount: "0.001", native_amount: "66.58")
      ]
    })

    CoinbaseAccount::Processor.new(@coinbase_account).process

    entry = @account.entries.find_by!(external_id: "coinbase_txn_txn_reward_1")
    assert_equal "Dividend", entry.entryable.investment_activity_label
    assert_equal BigDecimal("-66.58"), entry.amount
    assert_equal BigDecimal("0.001"), entry.entryable.qty
  end

  test "maps an ambiguous send to Transfer instead of a cost-basis-affecting Other" do
    CoinbaseAccount::HoldingsProcessor.any_instance.stubs(:process).returns(nil)
    @coinbase_account.update!(raw_transactions_payload: {
      "transactions" => [
        coinbase_txn(id: "txn_send_1", type: "send", btc_amount: "0.01", native_amount: "665.80")
      ]
    })

    CoinbaseAccount::Processor.new(@coinbase_account).process

    entry = @account.entries.find_by!(external_id: "coinbase_txn_txn_send_1")
    assert_equal "Transfer", entry.entryable.investment_activity_label
    assert entry.entryable.internal_movement?
    assert_equal 0.to_d, entry.amount
  end

  test "imports exchange_withdrawal and vault_withdrawal instead of dropping them" do
    CoinbaseAccount::HoldingsProcessor.any_instance.stubs(:process).returns(nil)
    @coinbase_account.update!(raw_transactions_payload: {
      "transactions" => [
        coinbase_txn(id: "txn_ew", type: "exchange_withdrawal", btc_amount: "-0.02", native_amount: "1331.60"),
        coinbase_txn(id: "txn_vw", type: "vault_withdrawal", btc_amount: "-0.03", native_amount: "1997.40")
      ]
    })

    CoinbaseAccount::Processor.new(@coinbase_account).process

    assert @account.entries.exists?(external_id: "coinbase_txn_txn_ew")
    assert @account.entries.exists?(external_id: "coinbase_txn_txn_vw")
  end

  test "does not shadow a send with an opposite-direction transfer of the same magnitude" do
    CoinbaseAccount::HoldingsProcessor.any_instance.stubs(:process).returns(nil)
    @coinbase_account.update!(raw_transactions_payload: {
      "transactions" => [
        coinbase_txn(id: "txn_send_real", type: "send", btc_amount: "0.01", native_amount: "665.80"),
        coinbase_txn(id: "txn_pro_withdraw", type: "pro_withdrawal", btc_amount: "-0.01", native_amount: "665.80")
      ]
    })

    CoinbaseAccount::Processor.new(@coinbase_account).process

    assert @account.entries.exists?(external_id: "coinbase_txn_txn_send_real"),
      "an unrelated same-day transfer in the opposite direction must not shadow a real send"
    assert @account.entries.exists?(external_id: "coinbase_txn_txn_pro_withdraw")
  end

  test "still shadows a send that duplicates a specific completed transfer in the same direction" do
    CoinbaseAccount::HoldingsProcessor.any_instance.stubs(:process).returns(nil)
    @coinbase_account.update!(raw_transactions_payload: {
      "transactions" => [
        coinbase_txn(id: "txn_send_dup", type: "send", btc_amount: "-0.01", native_amount: "665.80"),
        coinbase_txn(id: "txn_pro_withdraw_dup", type: "pro_withdrawal", btc_amount: "-0.01", native_amount: "665.80")
      ]
    })

    CoinbaseAccount::Processor.new(@coinbase_account).process

    refute @account.entries.exists?(external_id: "coinbase_txn_txn_send_dup")
    assert @account.entries.exists?(external_id: "coinbase_txn_txn_pro_withdraw_dup")
  end

  test "does not let a pending sibling shadow a completed send" do
    CoinbaseAccount::HoldingsProcessor.any_instance.stubs(:process).returns(nil)
    @coinbase_account.update!(raw_transactions_payload: {
      "transactions" => [
        coinbase_txn(id: "txn_send_pending_sib", type: "send", btc_amount: "-0.01", native_amount: "665.80"),
        coinbase_txn(id: "txn_pro_pending", type: "pro_withdrawal", btc_amount: "-0.01", native_amount: "665.80", status: "pending")
      ]
    })

    CoinbaseAccount::Processor.new(@coinbase_account).process

    assert @account.entries.exists?(external_id: "coinbase_txn_txn_send_pending_sib"),
      "a pending sibling never actually happened, so it can't shadow anything"
  end

  test "removes a previously-imported send once its matching transfer becomes visible" do
    CoinbaseAccount::HoldingsProcessor.any_instance.stubs(:process).returns(nil)
    send_txn = coinbase_txn(id: "txn_send_later_shadowed", type: "send", btc_amount: "-0.01", native_amount: "665.80")
    sibling_txn = coinbase_txn(id: "txn_pro_withdraw_later", type: "pro_withdrawal", btc_amount: "-0.01", native_amount: "665.80")

    # A rate-limited partial fetch (Provider::Coinbase::PartialResultError)
    # can import this send on one sync before its sibling is ever fetched,
    # so it isn't shadowed yet.
    @coinbase_account.update!(raw_transactions_payload: { "transactions" => [ send_txn ] })
    CoinbaseAccount::Processor.new(@coinbase_account).process
    assert @account.entries.exists?(external_id: "coinbase_txn_txn_send_later_shadowed")

    # A later, more complete sync makes the sibling visible. The send is now
    # shadowed -- its stale duplicate must be removed, leaving only the
    # sibling's own entry.
    @coinbase_account.update!(raw_transactions_payload: { "transactions" => [ send_txn, sibling_txn ] })
    CoinbaseAccount::Processor.new(@coinbase_account).process

    refute @account.entries.exists?(external_id: "coinbase_txn_txn_send_later_shadowed")
    assert @account.entries.exists?(external_id: "coinbase_txn_txn_pro_withdraw_later")
  end

  test "keeps the send when its matching transfer sibling fails to import" do
    CoinbaseAccount::HoldingsProcessor.any_instance.stubs(:process).returns(nil)
    send_txn = coinbase_txn(id: "txn_send_keep", type: "send", btc_amount: "-0.01", native_amount: "665.80")
    # An unparseable created_at fails before the sibling's entry is ever
    # created, same as any other per-transaction processing failure.
    broken_sibling = coinbase_txn(
      id: "txn_pro_withdraw_broken", type: "pro_withdrawal", btc_amount: "-0.01",
      native_amount: "665.80", created_at: "not-a-real-date"
    )

    @coinbase_account.update!(raw_transactions_payload: { "transactions" => [ send_txn ] })
    CoinbaseAccount::Processor.new(@coinbase_account).process
    assert @account.entries.exists?(external_id: "coinbase_txn_txn_send_keep")

    @coinbase_account.update!(raw_transactions_payload: { "transactions" => [ send_txn, broken_sibling ] })
    CoinbaseAccount::Processor.new(@coinbase_account).process

    assert @account.entries.exists?(external_id: "coinbase_txn_txn_send_keep"),
      "the send must survive when its matching sibling fails to import -- otherwise the account has neither entry"
    refute @account.entries.exists?(external_id: "coinbase_txn_txn_pro_withdraw_broken")
  end

  test "does not destroy a protected send when its matching transfer becomes visible" do
    CoinbaseAccount::HoldingsProcessor.any_instance.stubs(:process).returns(nil)
    send_txn = coinbase_txn(id: "txn_send_protected", type: "send", btc_amount: "-0.01", native_amount: "665.80")
    sibling_txn = coinbase_txn(id: "txn_pro_withdraw_protected", type: "pro_withdrawal", btc_amount: "-0.01", native_amount: "665.80")

    @coinbase_account.update!(raw_transactions_payload: { "transactions" => [ send_txn ] })
    CoinbaseAccount::Processor.new(@coinbase_account).process
    # A user's deliberate exclusion must survive sync-driven reconciliation,
    # same as every other provider's sync code respects protected_from_sync?.
    @account.entries.find_by!(external_id: "coinbase_txn_txn_send_protected").update!(excluded: true)

    @coinbase_account.update!(raw_transactions_payload: { "transactions" => [ send_txn, sibling_txn ] })
    CoinbaseAccount::Processor.new(@coinbase_account).process

    assert @account.entries.exists?(external_id: "coinbase_txn_txn_send_protected"),
      "a user-excluded entry must never be silently destroyed by sync reconciliation"
    assert @account.entries.exists?(external_id: "coinbase_txn_txn_pro_withdraw_protected")
  end

  test "captures a per-transaction processing failure via DebugLogEntry" do
    CoinbaseAccount::HoldingsProcessor.any_instance.stubs(:process).returns(nil)
    @coinbase_account.update!(raw_transactions_payload: {
      "transactions" => [
        coinbase_txn(id: "txn_bad", type: "staking_reward", btc_amount: "0.001", native_amount: "66.58", created_at: "not-a-real-date")
      ]
    })

    assert_difference -> { DebugLogEntry.count }, 1 do
      CoinbaseAccount::Processor.new(@coinbase_account).process
    end

    entry = DebugLogEntry.last
    assert_equal "provider_sync_error", entry.category
    assert_equal "coinbase", entry.provider_key
    assert_equal @family, entry.family
  end

  private

    def coinbase_txn(id:, type:, btc_amount:, native_amount:, created_at: "2026-01-01T00:00:00Z", status: "completed")
      {
        "id" => id,
        "type" => type,
        "status" => status,
        "created_at" => created_at,
        "amount" => { "amount" => btc_amount, "currency" => "BTC" },
        "native_amount" => { "amount" => native_amount, "currency" => "USD" }
      }
    end
end
