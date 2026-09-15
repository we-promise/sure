# frozen_string_literal: true

require "test_helper"

# Tests PluggyAccount::Processor#process — the per-account dispatcher invoked by
# PluggyItem#process_accounts. Banking accounts delegate to the transactions
# processor; investment accounts delegate to the holdings processor. Balance is
# upserted in both branches. Mirrors the AkahuAccount::ProcessorTest pattern of
# stubbing current_account + child processors rather than wiring a full sync.
class PluggyAccount::ProcessorTest < ActiveSupport::TestCase
  setup do
    @pluggy_account = pluggy_accounts(:one)

    # Stub the linked Sure account so balance upsert + broadcast stay isolated.
    @account = stub("Account",
                    id: 1,
                    accountable_type: "Depository",
                    currency: "USD",
                    assign_attributes: true,
                    save!: true,
                    set_current_balance: true,
                    broadcast_sync_complete: true)
    @pluggy_account.stubs(:current_account).returns(@account)
    @pluggy_account.stubs(:currency).returns("BRL")
  end

  test "process dispatches banking transactions processor for a banking account" do
    @pluggy_account.stubs(:account_type).returns("checking")
    @pluggy_account.stubs(:raw_payload).returns("type" => "checking")
    @pluggy_account.stubs(:raw_transactions_payload).returns([ { "id" => "tx-1" } ])
    @pluggy_account.stubs(:current_balance).returns(100.0)

    PluggyAccount::Transactions::Processor.any_instance.expects(:process).once

    result = PluggyAccount::Processor.new(@pluggy_account).process
    assert result[:transactions]
  end

  test "process dispatches holdings processor for an investment account" do
    @pluggy_account.stubs(:account_type).returns("investment")
    @pluggy_account.stubs(:raw_payload).returns("type" => "investment")
    @pluggy_account.stubs(:raw_holdings_payload).returns([ { "code" => "PETR4" } ])
    @pluggy_account.stubs(:raw_activities_payload).returns([])
    @pluggy_account.stubs(:current_balance).returns(5000.0)

    # Investment path re-anchors balance from holdings after import, so the
    # holdings relation must respond on the strict Account mock.
    stub_holdings_relation(sum: 5000.0)

    PluggyAccount::Investments::HoldingsProcessor.any_instance.expects(:process).once

    result = PluggyAccount::Processor.new(@pluggy_account).process
    assert result[:holdings]
  end

  # Regression: "investimento continua zerado". A Pluggy investment container —
  # especially the synthesized one the Importer builds when /accounts exposes no
  # investment-type row — reports balance 0, so the balance Pluggy exposes must
  # NOT anchor the linked Investment Account. The account's value comes from the
  # holdings just imported for Date.current; the processor must re-derive +
  # re-anchor from those, mirroring Coinbase's holdings-value fallback. Before
  # the fix the processor anchored to current_balance (0) first and never
  # re-anchored → account.balance = 0 and the holdings chart stayed flat.
  test "process anchors investment balance to holdings sum, not the container's zero balance" do
    @pluggy_account.stubs(:account_type).returns("investment")
    @pluggy_account.stubs(:raw_payload).returns("type" => "investment")
    @pluggy_account.stubs(:raw_holdings_payload).returns([ { "code" => "PETR4" } ])
    @pluggy_account.stubs(:raw_activities_payload).returns([])
    @pluggy_account.stubs(:current_balance).returns(0) # synthesized container
    @pluggy_account.stubs(:currency).returns("BRL")

    stub_holdings_relation(sum: 5000.0)

    PluggyAccount::Investments::HoldingsProcessor.any_instance.stubs(:process)

    # The synthetic investment container reports balance 0; the fix re-anchors the
    # linked Account from holdings just imported (sum 5000), with no brokerage
    # cash. `expects(...).with(...).once` verifies the EXACT call reached @account
    # (and pins balance-from-holdings vs the 0 container) without relying on a
    # block-capture stub, which Mocha 2.7.1 doesn't reliably delegate for kwargs.
    @account.expects(:assign_attributes).with(
      balance: 5000,
      cash_balance: 0,
      currency: "BRL"
    ).once

    result = PluggyAccount::Processor.new(@pluggy_account).process

    assert result[:holdings]
  end

  # Regression: provider-scope the investment-balance holdings sum. An Account can
  # carry holdings from multiple providers (or manual entries) when a Pluggy link is
  # added to an account that already had holdings; summing ALL of them for the date
  # would double-count the non-Pluggy value into the balance. The fix scopes the sum
  # to THIS provider's holdings (account_provider_id), mirroring HoldingsProcessor's
  # own provider scoping at l61. Here the unscoped sum (8000) would book another
  # provider's 3000 into this Pluggy account's balance; the fixed, provider-scoped
  # sum is 5000 — `expects(...).with(balance: 5000)` fails under the old unscoped path.
  test "process scopes investment balance to this provider's holdings only" do
    @pluggy_account.stubs(:account_type).returns("investment")
    @pluggy_account.stubs(:raw_payload).returns("type" => "investment")
    @pluggy_account.stubs(:raw_holdings_payload).returns([ { "code" => "PETR4" } ])
    @pluggy_account.stubs(:raw_activities_payload).returns([])
    @pluggy_account.stubs(:current_balance).returns(0)
    @pluggy_account.stubs(:currency).returns("BRL")
    @pluggy_account.stubs(:account_provider).returns(OpenStruct.new(id: 42))

    stub_provider_scoped_holdings_relation(provider_scoped_sum: 5000, unscoped_sum: 8000)

    PluggyAccount::Investments::HoldingsProcessor.any_instance.stubs(:process)

    @account.expects(:assign_attributes).with(
      balance: 5000,
      cash_balance: 0,
      currency: "BRL"
    ).once

    result = PluggyAccount::Processor.new(@pluggy_account).process

    assert result[:holdings]
  end

  test "process returns nil when no linked account" do
    @pluggy_account.stubs(:current_account).returns(nil)

    assert_nil PluggyAccount::Processor.new(@pluggy_account).process
  end

  test "process re-raises Pluggy authentication errors" do
    @pluggy_account.stubs(:account_type).returns("checking")
    @pluggy_account.stubs(:raw_payload).returns("type" => "checking")
    @pluggy_account.stubs(:raw_transactions_payload).returns([ { "id" => "tx-1" } ])
    @pluggy_account.stubs(:current_balance).returns(100.0)

    PluggyAccount::Transactions::Processor.any_instance.stubs(:process).raises(
      Provider::Pluggy::AuthenticationError.new("Invalid credentials", :unauthorized)
    )

    assert_raises(Provider::Pluggy::AuthenticationError) do
      PluggyAccount::Processor.new(@pluggy_account).process
    end
  end

  private

    # Stubs the chain `account.holdings.where(date: Date.current).sum(:amount)`
    # on the strict Account mock so the investment balance re-anchor can run.
    def stub_holdings_relation(sum:)
      holdings_relation = stub("HoldingsRelation")
      holdings_relation.stubs(:where).with(date: Date.current).returns(holdings_relation)
      holdings_relation.stubs(:sum).with(:amount).returns(sum)
      @account.stubs(:holdings).returns(holdings_relation)
    end

    # Two-level holdings chain for the provider-scoped balance path:
    # `account.holdings.where(date: Date.current)` → date_scoped, then
    # `date_scoped.where(account_provider_id: <id>)` → provider_scoped, then
    # `.sum(:amount)`. The UNscoped sum on date_scoped returns `unscoped_sum` so a
    # regression that drops the provider scope would book `unscoped_sum` (8000) into
    # the balance — the test's `expects(balance: provider_scoped_sum)` then fails,
    # which is the regression signal.
    def stub_provider_scoped_holdings_relation(provider_scoped_sum:, unscoped_sum:)
      date_scoped = stub("DateScopedHoldings")
      provider_scoped = stub("ProviderScopedHoldings")
      date_scoped.stubs(:where).with(account_provider_id: 42).returns(provider_scoped)
      date_scoped.stubs(:sum).with(:amount).returns(unscoped_sum)
      provider_scoped.stubs(:sum).with(:amount).returns(provider_scoped_sum)
      holdings_relation = stub("HoldingsRelation")
      holdings_relation.stubs(:where).with(date: Date.current).returns(date_scoped)
      @account.stubs(:holdings).returns(holdings_relation)
    end
end
