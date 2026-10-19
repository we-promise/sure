require "test_helper"

class EnableBankingItem::DuplicateRepairTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @user = users(:family_admin)
    @item = EnableBankingItem.create!(
      family: @family,
      name: "Fineco",
      country_code: "IT",
      aspsp_name: "FinecoBank",
      application_id: "test-app",
      client_certificate: "test-certificate"
    )
  end

  test "dry run validates a pair without changing either account or provider link" do
    pair = build_pair("EUR")
    duplicate_fingerprint = pair[:duplicate].enable_banking_fingerprint

    result = repair(pair).call

    assert_equal :safe_to_repair, result.status
    assert_equal 1, result.pairs
    assert_equal 1, result.accounts_removed
    assert Account.exists?(pair[:duplicate].id)
    assert_equal pair[:duplicate].id, pair[:provider_account].reload.account.id
    assert_equal duplicate_fingerprint, pair[:duplicate].reload.enable_banking_fingerprint
    assert_nil pair[:canonical].reload.enable_banking_fingerprint
  end

  test "repair preserves native transactions and valid transfer links while removing same-account suggestions" do
    pair = build_pair("EUR")
    date = Date.current
    old_debit = provider_transaction(pair[:canonical], external_id: "debit", amount: 10, date:)
    new_debit = provider_transaction(pair[:duplicate], external_id: "debit", amount: 10, date:)
    old_credit = provider_transaction(pair[:canonical], external_id: "credit", amount: -10, date:)
    new_credit = provider_transaction(pair[:duplicate], external_id: "credit", amount: -10, date:)
    old_revolut_credit = provider_transaction(pair[:canonical], external_id: "revolut-credit", amount: -75, date:)
    new_revolut_credit = provider_transaction(pair[:duplicate], external_id: "revolut-credit", amount: -75, date:)
    old_bper_credit = provider_transaction(pair[:canonical], external_id: "bper-credit", amount: -30, date:)
    provider_transaction(pair[:duplicate], external_id: "bper-credit", amount: -30, date:)

    same_account_suggestion = create_pending_transfer(
      outflow: old_debit.transaction,
      inflow: new_credit.transaction
    )
    revolut = account("Revolut", currency: "EUR")
    revolut_outflow = provider_transaction(revolut, external_id: "revolut-debit", amount: 75, date:)
    cross_bank_suggestion = create_pending_transfer(
      outflow: revolut_outflow.transaction,
      inflow: new_revolut_credit.transaction
    )
    bper = account("BPER", currency: "EUR")
    bper_outflow = provider_transaction(bper, external_id: "bper-debit", amount: 30, date:)
    existing_bper_suggestion = create_pending_transfer(
      outflow: bper_outflow.transaction,
      inflow: old_bper_credit.transaction
    )

    opening_date = Date.new(2024, 10, 17)
    anchor_date = Date.new(2026, 10, 17)
    new_anchor_date = Date.new(2026, 10, 18)
    canonical_opening = valuation(pair[:canonical], opening_date, 20, :opening_anchor)
    duplicate_opening = valuation(pair[:duplicate], opening_date, 20, :opening_anchor)
    canonical_current = valuation(pair[:canonical], anchor_date, 100, :current_anchor, notes: "Daily snapshot")
    duplicate_reconciliation = valuation(pair[:duplicate], anchor_date, 100, :reconciliation, notes: "Daily snapshot")
    duplicate_current = valuation(pair[:duplicate], new_anchor_date, 125, :current_anchor)
    pair[:canonical].update!(balance: 125, cash_balance: 125)
    pair[:duplicate].update!(balance: 125, cash_balance: 125)

    result = repair(pair).call(dry_run: false)

    assert_equal :repaired, result.status
    assert_equal 4, result.transactions_preserved
    assert_equal 4, result.duplicate_transactions_removed
    assert_equal 1, result.transfers_destroyed
    assert_equal 1, result.transfers_remapped
    assert_equal 1, result.valuations_moved
    assert_equal 2, result.valuations_deduplicated
    assert_equal 1, result.accounts_removed

    assert_not Account.exists?(pair[:duplicate].id)
    assert_equal pair[:canonical].id, pair[:provider_account].reload.account.id
    assert_equal pair[:provider_account].reconnection_fingerprint, pair[:canonical].reload.enable_banking_fingerprint
    assert_equal "FinecoBank", pair[:canonical].reload.institution_name
    assert_equal BigDecimal("125"), pair[:canonical].balance
    assert_equal BigDecimal("125"), pair[:canonical].cash_balance

    assert_equal old_debit.id, Entry.find_by!(account: pair[:canonical], source: "enable_banking", external_id: "enable_banking_debit").id
    assert_equal old_credit.id, Entry.find_by!(account: pair[:canonical], source: "enable_banking", external_id: "enable_banking_credit").id
    assert_equal old_revolut_credit.id, Entry.find_by!(account: pair[:canonical], source: "enable_banking", external_id: "enable_banking_revolut-credit").id
    assert_not Transaction.exists?(new_debit.transaction.id)
    assert_not Transaction.exists?(new_credit.transaction.id)
    assert_not Transaction.exists?(new_revolut_credit.transaction.id)

    assert_not Transfer.exists?(same_account_suggestion.id)
    assert_equal "pending", cross_bank_suggestion.reload.status
    assert_equal old_revolut_credit.transaction.id, cross_bank_suggestion.inflow_transaction_id
    assert_equal "pending", existing_bper_suggestion.reload.status
    assert_equal old_bper_credit.transaction.id, existing_bper_suggestion.inflow_transaction_id

    assert_equal "reconciliation", canonical_current.entryable.reload.kind
    assert_equal Valuation.build_reconciliation_name("Depository"), canonical_current.reload.name
    assert_not Entry.exists?(duplicate_reconciliation.id)
    assert_not Entry.exists?(duplicate_opening.id)
    assert_equal canonical_opening.id, Entry.find_by!(account: pair[:canonical], date: opening_date, entryable_type: "Valuation").id
    assert_equal duplicate_current.id, Entry.find(duplicate_current.id).id
    assert_equal pair[:canonical].id, Entry.find(duplicate_current.id).account_id
    assert_equal 1, pair[:canonical].valuations.current_anchor.count

    repeated = repair(pair).call(dry_run: false)
    assert_equal :already_repaired, repeated.status
    assert_equal 0, repeated.accounts_removed
    assert_equal pair[:canonical].id, pair[:provider_account].reload.account.id
  end

  test "annotation conflicts abort the full repair before moving the provider link" do
    pair = build_pair("GBP")
    canonical_entry = provider_transaction(pair[:canonical], external_id: "payment", amount: 15)
    duplicate_entry = provider_transaction(pair[:duplicate], external_id: "payment", amount: 15, notes: "different note")

    assert_raises(EnableBankingItem::DuplicateRepair::UnsafeRepairError) do
      repair(pair).call(dry_run: false)
    end

    assert Account.exists?(pair[:duplicate].id)
    assert_equal pair[:duplicate].id, pair[:provider_account].reload.account.id
    assert Entry.exists?(canonical_entry.id)
    assert Entry.exists?(duplicate_entry.id)
    assert_nil pair[:canonical].reload.enable_banking_fingerprint
  end

  test "confirmed self-account matches abort instead of losing user-confirmed transfer data" do
    pair = build_pair("CHF")
    debit = provider_transaction(pair[:canonical], external_id: "debit", amount: 42)
    provider_transaction(pair[:duplicate], external_id: "debit", amount: 42)
    provider_transaction(pair[:canonical], external_id: "credit", amount: -42)
    credit = provider_transaction(pair[:duplicate], external_id: "credit", amount: -42)
    transfer = Transfer.create!(
      outflow_transaction: debit.transaction,
      inflow_transaction: credit.transaction,
      status: "confirmed",
      amount: 42
    )

    assert_raises(EnableBankingItem::DuplicateRepair::UnsafeRepairError) do
      repair(pair).call(dry_run: false)
    end

    assert Account.exists?(pair[:duplicate].id)
    assert_equal pair[:duplicate].id, pair[:provider_account].reload.account.id
    assert_equal "confirmed", transfer.reload.status
    assert_equal credit.transaction.id, transfer.inflow_transaction_id
  end

  test "a remapped transfer rejected against the canonical transaction aborts safely" do
    pair = build_pair("USD")
    duplicate_credit = provider_transaction(pair[:duplicate], external_id: "bank-credit", amount: -60)
    revolut = account("Revolut USD", currency: "USD")
    revolut_debit = provider_transaction(revolut, external_id: "revolut-debit", amount: 60)
    transfer = create_pending_transfer(outflow: revolut_debit.transaction, inflow: duplicate_credit.transaction)
    RejectedTransfer.create!(
      outflow_transaction: revolut_debit.transaction,
      inflow_transaction: provider_transaction(pair[:canonical], external_id: "bank-credit", amount: -60).transaction
    )

    assert_raises(EnableBankingItem::DuplicateRepair::UnsafeRepairError) do
      repair(pair).call(dry_run: false)
    end

    assert Account.exists?(pair[:duplicate].id)
    assert_equal pair[:duplicate].id, pair[:provider_account].reload.account.id
    assert_equal duplicate_credit.transaction.id, transfer.reload.inflow_transaction_id
  end

  test "rejected matches involving duplicate transactions abort even without an active transfer" do
    pair = build_pair("CAD")
    duplicate_credit = provider_transaction(pair[:duplicate], external_id: "bank-credit", amount: -60)
    provider_transaction(pair[:canonical], external_id: "bank-credit", amount: -60)
    revolut = account("Revolut CAD", currency: "CAD")
    revolut_debit = provider_transaction(revolut, external_id: "revolut-debit", amount: 60)
    RejectedTransfer.create!(
      outflow_transaction: revolut_debit.transaction,
      inflow_transaction: duplicate_credit.transaction
    )

    assert_raises(EnableBankingItem::DuplicateRepair::UnsafeRepairError) do
      repair(pair).call(dry_run: false)
    end

    assert Account.exists?(pair[:duplicate].id)
    assert_equal pair[:duplicate].id, pair[:provider_account].reload.account.id
  end

  private
    def build_pair(currency)
      canonical = account("Native #{currency}", currency:)
      duplicate = account("Enable Banking #{currency}", currency:)
      provider_account = @item.enable_banking_accounts.create!(
        name: "Fineco #{currency}",
        uid: "fineco-#{currency.downcase}",
        currency:,
        current_balance: 100,
        raw_payload: { "identification_hash" => "primary-#{currency.downcase}" }
      )
      AccountProvider.create!(account: duplicate, provider: provider_account)

      {
        canonical:,
        duplicate:,
        provider_account:,
        pair: {
          canonical_account_id: canonical.id,
          duplicate_account_id: duplicate.id,
          provider_account_id: provider_account.id
        }
      }
    end

    def account(name, currency:)
      Account.create!(
        family: @family,
        owner: @user,
        name:,
        balance: 100,
        cash_balance: 100,
        currency:,
        accountable: Depository.create!(subtype: "checking"),
        status: "active"
      )
    end

    def provider_transaction(account, external_id:, amount:, date: Date.current, notes: nil)
      transaction = Transaction.create!(kind: "standard")
      Entry.create!(
        account:,
        date:,
        amount:,
        currency: account.currency,
        name: "Bank transaction #{external_id}",
        notes:,
        source: "enable_banking",
        external_id: "enable_banking_#{external_id}",
        entryable: transaction
      )
    end

    def valuation(account, date, amount, kind, notes: nil)
      name = case kind
      when :opening_anchor then Valuation.build_opening_anchor_name(account.accountable_type)
      when :current_anchor then Valuation.build_current_anchor_name(account.accountable_type)
      else Valuation.build_reconciliation_name(account.accountable_type)
      end
      Entry.create!(
        account:,
        date:,
        amount:,
        currency: account.currency,
        name:,
        notes:,
        entryable: Valuation.new(kind:)
      )
    end

    def create_pending_transfer(outflow:, inflow:)
      Transfer.create!(
        outflow_transaction: outflow,
        inflow_transaction: inflow,
        status: "pending",
        amount: outflow.entry.amount.abs
      )
    end

    def repair(pair)
      EnableBankingItem::DuplicateRepair.new(@item, user: @user, pairs: [ pair[:pair] ])
    end
end
