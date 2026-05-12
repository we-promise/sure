require "test_helper"

class AccountTest < ActiveSupport::TestCase
  include SyncableInterfaceTest, EntriesTestHelper, ActiveJob::TestHelper

  setup do
    @account = @syncable = accounts(:depository)
    @family = families(:dylan_family)
    @admin = users(:family_admin)
    @member = users(:family_member)
  end

  test "can destroy" do
    assert_difference "Account.count", -1 do
      @account.destroy
    end
  end

  test "create_and_sync calls sync_later by default" do
    Account.any_instance.expects(:sync_later).once

    account = Account.create_and_sync({
      family: @family,
      owner: @admin,
      name: "Test Account",
      balance: 100,
      currency: "USD",
      accountable_type: "Depository",
      accountable_attributes: {}
    })

    assert account.persisted?
    assert_equal "USD", account.currency
    assert_equal 100, account.balance
  end

  test "create_and_sync skips sync_later when skip_initial_sync is true" do
    Account.any_instance.expects(:sync_later).never

    account = Account.create_and_sync(
      {
        family: @family,
        owner: @admin,
        name: "Linked Account",
        balance: 500,
        currency: "EUR",
        accountable_type: "Depository",
        accountable_attributes: {}
      },
      skip_initial_sync: true
    )

    assert account.persisted?
    assert_equal "EUR", account.currency
    assert_equal 500, account.balance
  end

  test "create_and_sync creates opening anchor with correct currency" do
    Account.any_instance.stubs(:sync_later)

    account = Account.create_and_sync(
      {
        family: @family,
        owner: @admin,
        name: "Test Account",
        balance: 1000,
        currency: "GBP",
        accountable_type: "Depository",
        accountable_attributes: {}
      },
      skip_initial_sync: true
    )

    opening_anchor = account.valuations.opening_anchor.first
    assert_not_nil opening_anchor
    assert_equal "GBP", opening_anchor.entry.currency
    assert_equal 1000, opening_anchor.entry.amount
  end

  test "create_and_sync uses provided opening balance date" do
    Account.any_instance.stubs(:sync_later)
    opening_date = Time.zone.today

    account = Account.create_and_sync(
      {
        family: @family,
        owner: @admin,
        name: "Test Account",
        balance: 1000,
        currency: "USD",
        accountable_type: "Depository",
        accountable_attributes: {}
      },
      skip_initial_sync: true,
      opening_balance_date: opening_date
    )

    opening_anchor = account.valuations.opening_anchor.first
    assert_equal opening_date, opening_anchor.entry.date
  end

  test "gets short/long subtype label" do
    investment = Investment.new(subtype: "hsa")
    account = @family.accounts.create!(
      owner: @admin,
      name: "Test Investment",
      balance: 1000,
      currency: "USD",
      accountable: investment
    )

    assert_equal "HSA", account.short_subtype_label
    assert_equal "Health Savings Account", account.long_subtype_label

    # Test with nil subtype
    account.accountable.update!(subtype: nil)
    assert_equal "Investments", account.short_subtype_label
    assert_equal "Investments", account.long_subtype_label
  end

  # Tax treatment tests (TaxTreatable concern)

  test "tax_treatment delegates to accountable for Investment" do
    investment = Investment.new(subtype: "401k")
    account = @family.accounts.create!(
      owner: @admin,
      name: "Test 401k",
      balance: 1000,
      currency: "USD",
      accountable: investment
    )

    assert_equal :tax_deferred, account.tax_treatment
    assert_equal I18n.t("accounts.tax_treatments.tax_deferred"), account.tax_treatment_label
  end

  test "tax_treatment delegates to accountable for Crypto" do
    crypto = Crypto.new(tax_treatment: :taxable)
    account = @family.accounts.create!(
      owner: @admin,
      name: "Test Crypto",
      balance: 500,
      currency: "USD",
      accountable: crypto
    )

    assert_equal :taxable, account.tax_treatment
    assert_equal I18n.t("accounts.tax_treatments.taxable"), account.tax_treatment_label
  end

  test "tax_treatment returns nil for non-investment accounts" do
    # Depository accounts don't have tax_treatment
    assert_nil @account.tax_treatment
    assert_nil @account.tax_treatment_label
  end

  test "tax_advantaged? returns true for tax-advantaged accounts" do
    investment = Investment.new(subtype: "401k")
    account = @family.accounts.create!(
      owner: @admin,
      name: "Test 401k",
      balance: 1000,
      currency: "USD",
      accountable: investment
    )

    assert account.tax_advantaged?
    assert_not account.taxable?
  end

  test "tax_advantaged? returns false for taxable accounts" do
    investment = Investment.new(subtype: "brokerage")
    account = @family.accounts.create!(
      owner: @admin,
      name: "Test Brokerage",
      balance: 1000,
      currency: "USD",
      accountable: investment
    )

    assert_not account.tax_advantaged?
    assert account.taxable?
  end

  test "taxable? returns true for accounts without tax_treatment" do
    # Depository accounts
    assert @account.taxable?
    assert_not @account.tax_advantaged?
  end

  test "destroying account purges attached logo" do
    @account.logo.attach(
      io: StringIO.new("fake-logo-content"),
      filename: "logo.png",
      content_type: "image/png"
    )

    attachment_id = @account.logo.id
    assert ActiveStorage::Attachment.exists?(attachment_id)

    perform_enqueued_jobs do
      @account.destroy!
    end

    assert_not ActiveStorage::Attachment.exists?(attachment_id)
  end

  # Account sharing tests

  test "owned_by? returns true for account owner" do
    assert @account.owned_by?(@admin)
    assert_not @account.owned_by?(@member)
  end

  test "shared_with? returns true for owner and shared users" do
    assert @account.shared_with?(@admin) # owner
    # depository already shared with member via fixture
    assert @account.shared_with?(@member)
  end

  test "shared? returns true when account has shares" do
    account = accounts(:investment)
    account.account_shares.destroy_all
    assert_not account.shared?

    account.share_with!(@member, permission: "read_only")
    assert account.shared?
  end

  test "permission_for returns correct permission level" do
    assert_equal :owner, @account.permission_for(@admin)

    # depository already shared with member via fixture
    share = @account.account_shares.find_by(user: @member)
    share.update!(permission: "read_write")
    assert_equal :read_write, @account.permission_for(@member)
  end

  test "accessible_by scope returns owned and shared accounts" do
    # Clear existing shares for clean test
    AccountShare.delete_all

    admin_accessible = @family.accounts.accessible_by(@admin)
    member_accessible = @family.accounts.accessible_by(@member)

    # Admin owns all fixture accounts
    assert_equal @family.accounts.count, admin_accessible.count
    # Member has no access (no shares, no owned accounts)
    assert_equal 0, member_accessible.count

    # Share one account
    @account.share_with!(@member, permission: "read_only")
    member_accessible = @family.accounts.accessible_by(@member)
    assert_equal 1, member_accessible.count
    assert_includes member_accessible, @account
  end

  test "included_in_finances_for scope respects include_in_finances flag" do
    AccountShare.delete_all

    @account.share_with!(@member, permission: "read_only", include_in_finances: true)
    assert_includes @family.accounts.included_in_finances_for(@member), @account

    share = @account.account_shares.find_by(user: @member)
    share.update!(include_in_finances: false)
    assert_not_includes @family.accounts.included_in_finances_for(@member), @account
  end

  test "auto_share_with_family creates shares for all non-owner members" do
    @family.update!(default_account_sharing: "private")

    account = Account.create_and_sync({
      family: @family,
      owner: @admin,
      name: "New Shared Account",
      balance: 100,
      currency: "USD",
      accountable_type: "Depository",
      accountable_attributes: {}
    })

    assert_difference -> { AccountShare.count }, @family.users.where.not(id: @admin.id).count do
      account.auto_share_with_family!
    end

    share = account.account_shares.find_by(user: @member)
    assert_not_nil share
    assert_equal "read_write", share.permission
    assert share.include_in_finances?
  end

  test "current_holdings prefers latest provider snapshot holdings across currencies" do
    account = @family.accounts.create!(
      owner: @admin,
      name: "Linked Brokerage",
      balance: 1000,
      currency: "USD",
      accountable: Investment.new
    )

    coinstats_item = @family.coinstats_items.create!(name: "CoinStats", api_key: "test-key")
    coinstats_account = coinstats_item.coinstats_accounts.create!(name: "Brokerage", currency: "USD")
    account_provider = AccountProvider.create!(account: account, provider: coinstats_account)

    eur_security = Security.create!(ticker: "ASML", name: "ASML")
    chf_security = Security.create!(ticker: "NOVN", name: "Novartis")

    provider_holding = account.holdings.create!(
      security: eur_security,
      date: Date.current,
      qty: 2,
      price: 500,
      amount: 1000,
      currency: "EUR",
      account_provider: account_provider,
      cost_basis: 450
    )

    account.holdings.create!(
      security: eur_security,
      date: Date.current,
      qty: 2,
      price: 540,
      amount: 1080,
      currency: "USD"
    )

    second_provider_holding = account.holdings.create!(
      security: chf_security,
      date: Date.current,
      qty: 3,
      price: 90,
      amount: 270,
      currency: "CHF",
      account_provider: account_provider,
      cost_basis: 80
    )

    assert_equal [ provider_holding.id, second_provider_holding.id ].sort, account.current_holdings.pluck(:id).sort
    assert_equal %w[CHF EUR], account.current_holdings.pluck(:currency).sort
  end
end
