# frozen_string_literal: true

require "test_helper"

# Tests PluggyItem::AutoSetup — the first-sync auto-account-creation PORO. Proves
# that unlinked PluggyAccounts become real Accounts with the accountable type
# inferred from PluggyAccount#suggested_setup_account_type, that the
# AccountProvider link is wired (so has_completed_initial_setup? flips true), and
# that a second call is a no-op — the idempotency property that lets every
# subsequent sync skip auto-setup and fall through to the manual wizard.
class PluggyItem::AutoSetupTest < ActiveSupport::TestCase
  setup do
    @pluggy_item = PluggyItem.create!(
      family: families(:dylan_family),
      name: "AutoSetup Pluggy",
      client_id: "test_client",
      client_secret: "test_secret",
      pluggy_item_id: "item-auto-setup",
      status: :good
    )
  end

  test "creates Accounts with inferred accountable types for unlinked PluggyAccounts" do
    bank_pa    = @pluggy_item.pluggy_accounts.create!(pluggy_account_id: "bank-1",  name: "Checking",  currency: "USD", account_type: "credit",     current_balance: 1_000)
    loan_pa    = @pluggy_item.pluggy_accounts.create!(pluggy_account_id: "loan-1",  name: "Mortgage",  currency: "USD", account_type: "mortgage",   current_balance: 250_000)
    invest_pa  = @pluggy_item.pluggy_accounts.create!(pluggy_account_id: "inv-1",   name: "Brokerage", currency: "USD", account_type: "investment", current_balance: 50_000)
    unknown_pa = @pluggy_item.pluggy_accounts.create!(pluggy_account_id: "unk-1",   name: "Mystery",   currency: "USD", account_type: "whatever",  current_balance: 100)

    assert_difference -> { @pluggy_item.family.accounts.count }, +4 do
      PluggyItem::AutoSetup.new(@pluggy_item).call
    end

    # Bucket → accountable mapping mirrors ACCOUNTABLE_CLASS_NAMES in the PORO,
    # which is itself driven by suggested_setup_account_type's substring match.
    assert_equal "CreditCard", bank_pa.reload.account.accountable_type
    assert_equal "Loan",        loan_pa.reload.account.accountable_type
    assert_equal "Investment",  invest_pa.reload.account.accountable_type
    assert_equal "Depository",  unknown_pa.reload.account.accountable_type

    # Once linked, has_completed_initial_setup? is true → the syncer guard skips
    # auto-setup on every subsequent sync.
    assert_predicate @pluggy_item.reload, :has_completed_initial_setup?
  end

  test "is idempotent — a second call creates no new accounts" do
    @pluggy_item.pluggy_accounts.create!(pluggy_account_id: "bank-1", name: "Checking", currency: "USD", account_type: "credit", current_balance: 1_000)

    PluggyItem::AutoSetup.new(@pluggy_item).call
    created = @pluggy_item.family.accounts.count

    assert_no_difference -> { @pluggy_item.family.accounts.count } do
      PluggyItem::AutoSetup.new(@pluggy_item).call
    end

    assert_equal created, @pluggy_item.family.accounts.count
  end

  test "skips already-linked PluggyAccounts" do
    bank_pa = @pluggy_item.pluggy_accounts.create!(pluggy_account_id: "bank-1", name: "Checking", currency: "USD", account_type: "credit", current_balance: 1_000)
    existing = @pluggy_item.family.accounts.create!(name: "Existing Checking", balance: 500, currency: "USD", accountable: Depository.new)
    bank_pa.ensure_account_provider!(existing)

    assert_no_difference -> { @pluggy_item.family.accounts.count } do
      PluggyItem::AutoSetup.new(@pluggy_item).call
    end

    assert_equal existing, bank_pa.reload.account
  end

  test "per-account rescue keeps a bad row from aborting the parent setup" do
    good_pa = @pluggy_item.pluggy_accounts.create!(pluggy_account_id: "good-1", name: "Good", currency: "USD", account_type: "credit", current_balance: 1_000)
    bad_pa  = @pluggy_item.pluggy_accounts.create!(pluggy_account_id: "bad-1",  name: "Bad",  currency: "USD", account_type: "credit", current_balance: 1_000)

    # Simulate a per-row failure BEFORE account creation (no orphan Account left
    # behind): isolates the rescue question — does the good row still link?
    # PluggyItem#unlinked_pluggy_accounts issues a fresh SQL query and returns
    # newly-instantiated PluggyAccount objects, so a per-instance stub placed on
    # the local bad_pa reference would not fire on the records the PORO actually
    # iterates — the rescue path would never run. Stub the relation to return
    # these exact instances (the same idiom syncer_test.rb uses for
    # linked_pluggy_accounts) so the instance stub takes effect under the same
    # iteration the PORO uses in production.
    @pluggy_item.stubs(:unlinked_pluggy_accounts).returns([ good_pa, bad_pa ])
    bad_pa.stubs(:suggested_setup_account_type).raises(StandardError, "boom")

    assert_difference -> { @pluggy_item.family.accounts.count }, +1 do
      PluggyItem::AutoSetup.new(@pluggy_item).call
    end

    assert good_pa.reload.account_provider.present?
    assert_nil bad_pa.reload.account_provider
  ensure
    @pluggy_item.unstub(:unlinked_pluggy_accounts)
    bad_pa.unstub(:suggested_setup_account_type)
  end
end
