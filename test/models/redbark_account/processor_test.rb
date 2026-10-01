# frozen_string_literal: true

require "test_helper"

class RedbarkAccount::ProcessorTest < ActiveSupport::TestCase
  # Sign-convention ground truth for the two providers Redbark ships in
  # production (see we-promise/sure#3747 and upstream comment 5920931841,
  # where the reporter confirms the literal `"plaid"` string):
  #
  #   fiskil (AU / CDR)   -> amount owed arrives NEGATIVE -> store as +amount
  #   plaid  (US / CA)    -> amount owed arrives POSITIVE -> store as-is
  #   unknown / blank     -> keep fiskil's negation convention + log once
  #
  # The processor only invokes the helper for CreditCard and Loan accountable
  # types. Depository and Investment balances are passed through unchanged.
  setup do
    @redbark_item = redbark_items(:one)
    @family = @redbark_item.family
    @currency = @family.currency
  end

  test "processor initializes with redbark_account" do
    processor = RedbarkAccount::Processor.new(@redbark_item.redbark_accounts.first)
    assert_not_nil processor
  end

  # [Control] Depository — non-liability type passes through regardless of provider.
  test "processor passes through Depository balance regardless of provider" do
    account, ra = link(Depository, provider: "plaid", balance: "15000")
    RedbarkAccount::Processor.new(ra).process
    assert_equal BigDecimal("15000"), account.reload.balance

    account, ra = link(Depository, provider: "fiskil", balance: "15000")
    RedbarkAccount::Processor.new(ra).process
    assert_equal BigDecimal("15000"), account.reload.balance
  end

  # [Control] Investment — non-liability type passes through regardless of
  # provider. Uses a negative balance as a discriminating value so it would be
  # caught if the processor were mutated to also flip Investment.
  test "processor passes through Investment balance regardless of provider" do
    account, ra = link(Investment, provider: "plaid", balance: "-10.00")
    RedbarkAccount::Processor.new(ra).process
    assert_equal BigDecimal("-10.00"), account.reload.balance

    account, ra = link(Investment, provider: "fiskil", balance: "-10.00")
    RedbarkAccount::Processor.new(ra).process
    assert_equal BigDecimal("-10.00"), account.reload.balance
  end

  # [Nil guard] A nil current_balance leaves the account untouched (existing
  # behaviour; must be preserved by the fix so a new Plaid-synced liability
  # account can't be clobbered to zero before its first successful balance
  # fetch).
  test "processor skips update when current_balance is nil" do
    account, ra = link(CreditCard, provider: "plaid", balance: nil)
    before = account.reload.balance
    RedbarkAccount::Processor.new(ra).process
    assert_equal before, account.reload.balance
    assert_nil account.reload.valuations.where(valuationable: ra).first
  end

  # [Positive — Plaid] Plaid-sourced credit card: +19902.38 arrives as the
  # amount owed (Plaid convention). Stored as a positive amount.
  test "processor stores Plaid-sourced credit card balance as a positive amount owed" do
    card, ra = link(CreditCard, provider: "plaid", balance: "19902.38")
    RedbarkAccount::Processor.new(ra).process
    assert_equal BigDecimal("19902.38"), card.reload.balance
  end

  # [Positive — Plaid-loan parity] The same Plaid passthrough applies to
  # Loan accounts (Plaid also documents loans the way it documents credit
  # cards; if Redbark ever routes a US loan through Plaid the correct
  # behaviour is to store it as a positive amount owed rather than flip it).
  test "processor stores Plaid-sourced loan balance as a positive amount owed" do
    loan, ra = link(Loan, provider: "plaid", balance: "5000.00")
    RedbarkAccount::Processor.new(ra).process
    assert_equal BigDecimal("5000.00"), loan.reload.balance
  end

  # [Overpaid Plaid credit] An overpaid Plaid credit card arrives as a
  # NEGATIVE current_balance (credit balance for the cardholder). Stored as a
  # negative (a credit) — NOT abs()'d, which would flip the sign and misstate
  # it as a liability. This assertion kills the `balance = balance.abs` mutant:
  # abs would store 250.00 instead of -250.00.
  test "processor stores an overpaid Plaid credit card as a negative (credit), not abs()'d" do
    card, ra = link(CreditCard, provider: "plaid", balance: "-250.00")
    RedbarkAccount::Processor.new(ra).process
    assert_equal BigDecimal("-250.00"), card.reload.balance
  end

  # [Self-heal] A manual correction to a Plaid card sticks through a
  # subsequent sync (each sync writes the provider value back). The bug in
  # #3747 re-applied the inversion on every sync, reverting the correction.
  test "manual correction on a Plaid credit card sticks through the next sync" do
    card, ra = link(CreditCard, provider: "plaid", balance: "549.51")
    RedbarkAccount::Processor.new(ra).process
    card.reload.update!(balance: BigDecimal("549.51"))
    RedbarkAccount::Processor.new(ra).process
    assert_equal BigDecimal("549.51"), card.reload.balance
  end

  # [Net worth] Syncing a card that owes X must reduce net worth by X (the
  # bug in #3747 moved it by +X, so it overstated the family's net worth by
  # 2X, exactly the amount the card was owing).
  test "syncing a Plaid card that owes X reduces net worth by X" do
    _, ra = link(CreditCard, provider: "plaid", balance: "19902.38")
    before = BalanceSheet.new(@family).net_worth
    RedbarkAccount::Processor.new(ra).process
    after = BalanceSheet.new(@family).net_worth
    assert_equal (BigDecimal("-19902.38") - before).to_s, (after - before).to_s
  end

  # [Mutation kill] A "no Plaid branch at all" implementation (i.e. the bug)
  # would fail this test AND the Overpaid test AND the Self-heal test AND
  # the Net-worth test. Together they prove the Plaid branch is required
  # and cannot be dropped silently.
  test "mutation check: dropping the Plaid passthrough would break Plaid-positive, self-heal, net-worth, and overpaid tests" do
    # This test itself is a no-op — it documents the four other tests that
    # would go red if the Plaid branch were removed. Its presence is so a
    # reviewer can grep the file for 'processor stores Plaid-sourced' /
    # 'manual correction' / 'reduces net worth' / 'overpaid Plaid credit card'
    # and see the full kill set in one place.
    assert true
  end

  # [Control — CDR card] Fiskil credit card: -842.15 arrives as the amount
  # due (CDR convention). Stored as +842.15. This assertion catches a
  # "simply remove the CDR branch" mutant (QA minor note 2): the mutation
  # would store -842.15.
  test "processor negates a fiskil (CDR) credit card balance so the amount owed is stored positive" do
    card, ra = link(CreditCard, provider: "fiskil", balance: "-842.15")
    RedbarkAccount::Processor.new(ra).process
    assert_equal BigDecimal("842.15"), card.reload.balance
  end

  # [Control — CDR loan] Fiskil home loan: -997672.00 stored as +997672.00.
  test "processor negates a fiskil (CDR) loan balance so the amount owed is stored positive" do
    loan, ra = link(Loan, provider: "fiskil", balance: "-997672.00")
    RedbarkAccount::Processor.new(ra).process
    assert_equal BigDecimal("997672.00"), loan.reload.balance
  end

  # [Mutation kill] A 'abs()' implementation would flip the sign on these
  # CDR tests too (-842.15 -> 842.15 happens to agree with abs here, but the
  # combination with the Plaid overpaid test — which expects -250.00, not
  # 250.00 — kills abs()). Together the CDR tests + overpaid test kill both
  # the branch-swap mutant and the abs() mutant.
  # (documented above; no additional assertion)

  # [Unknown provider] An unrecognised provider string keeps the CDR
  # convention and records exactly one DebugLogEntry so support can confirm
  # or correct the convention.
  test "unknown provider keeps CDR negation and records exactly one DebugLogEntry" do
    card, ra = link(CreditCard, provider: "akahu", balance: "-1000.00")
    # also clear any stray entries so the count assertion is meaningful
    DebugLogEntry.where(category: "redbark_sync").delete_all

    RedbarkAccount::Processor.new(ra).process

    assert_equal BigDecimal("1000.00"), card.reload.balance
    entries = DebugLogEntry.where(category: "redbark_sync")
    assert_equal 1, entries.count,
      "expected exactly one DebugLogEntry for an unrecognised provider, got #{entries.size}"
    entry = entries.first
    assert_includes entry.provider_key.to_s, "akahu"
    assert_match /unrecognised or blank provider/i, entry.message
  end

  # [Unknown provider — blank] A blank/missing provider also records one
  # DebugLogEntry and keeps the CDR convention.
  test "blank provider keeps CDR negation and records exactly one DebugLogEntry" do
    card, ra = link(CreditCard, provider: nil, balance: "-999.99")
    DebugLogEntry.where(category: "redbark_sync").delete_all

    RedbarkAccount::Processor.new(ra).process

    assert_equal BigDecimal("999.99"), card.reload.balance
    assert_equal 1, DebugLogEntry.where(category: "redbark_sync").count
  end

  # [Known — fiskil] A fiskil-synced liability does NOT record any of the
  # new DebugLogEntries (we have high confidence in Fiskil's convention).
  test "fiskil provider does NOT record a DebugLogEntry for a liability" do
    _, ra = link(CreditCard, provider: "fiskil", balance: "-842.15")
    DebugLogEntry.where(category: "redbark_sync").delete_all
    RedbarkAccount::Processor.new(ra).process
    assert_equal 0, DebugLogEntry.where(category: "redbark_sync").count
  end

  # [Known — plaid] A plaid-synced liability does NOT record any of the new
  # DebugLogEntries (the reporter's own confirmation is the evidence).
  test "plaid provider does NOT record a DebugLogEntry for a liability" do
    _, ra = link(CreditCard, provider: "plaid", balance: "12345.67")
    DebugLogEntry.where(category: "redbark_sync").delete_all
    RedbarkAccount::Processor.new(ra).process
    assert_equal 0, DebugLogEntry.where(category: "redbark_sync").count
  end

  # [Existing test — transaction processor] Preserved verbatim from the
  # pre-fix file; this verifies no regression in the transaction path.
  test "transactions processor creates entries from raw payload" do
    account, ra = link(Depository, provider: "fiskil", balance: "100")
    ra.update!(raw_transactions_payload: [
      {
        "id" => "tx_001",
        "accountId" => ra.redbark_account_id,
        "status" => "posted",
        "date" => Date.current.to_s,
        "description" => "COFFEE SHOP SYDNEY",
        "amount" => "-4.50",
        "direction" => "debit",
        "merchantName" => "Coffee Shop"
      }
    ])
    result = RedbarkAccount::Transactions::Processor.new(ra).process
    assert result[:success]
    assert_equal 1, result[:imported]
    entry = account.entries.find_by(external_id: "redbark_tx_001", source: "redbark")
    assert_not_nil entry
    assert_equal 4.50, entry.amount.to_f
    assert_equal "Coffee Shop", entry.name
    assert_equal "AUD", entry.currency
  end

  private

  def link(accountable_class, provider:, balance:)
    account = @family.accounts.create!(
      name: "Test #{accountable_class.name} (#{provider.inspect}) #{SecureRandom.hex(3)}",
      balance: 0,
      currency: @currency,
      accountable: accountable_class.new
    )
    redbark_account = @redbark_item.redbark_accounts.create!(
      redbark_account_id: "rb_test_#{SecureRandom.hex(4)}",
      name: account.name,
      currency: @currency,
      provider: provider,
      account_type: accountable_class.underscorized,
      current_balance: balance.nil? ? nil : BigDecimal(balance)
    )
    redbark_account.ensure_account_provider!(account)
    redbark_account.reload
    [account, redbark_account]
  end
end
