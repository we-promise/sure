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

  test "subtype set as a top-level account attribute persists on create" do
    Account.any_instance.stubs(:sync_later)

    # Mirrors the create flow: the form submits `account[subtype]` as a
    # top-level attribute (not nested under accountable_attributes). The
    # accountable does not exist yet, so the delegating writer must build it.
    account = Account.create_and_sync({
      family: @family,
      owner: @admin,
      name: "Savings Account",
      balance: 100,
      currency: "USD",
      accountable_type: "Depository",
      subtype: "savings"
    })

    assert account.persisted?
    assert_equal "savings", account.reload.subtype
    assert_equal "savings", account.accountable.subtype
  end

  test "subtype assigned before accountable is built is not dropped" do
    account = Account.new
    account.accountable_type = "Depository"
    account.subtype = "checking"

    assert_not_nil account.accountable
    assert_equal "checking", account.subtype
  end

  test "subtype assigned before accountable_type is not dropped" do
    # The real controller path: strong-params `permit` preserves filter order,
    # and `account_params` lists `:subtype` before `:accountable_type`, so the
    # subtype writer runs while the type is still unknown.
    account = Account.new
    account.subtype = "savings"
    account.accountable_type = "Depository"

    assert_not_nil account.accountable
    assert_equal "savings", account.subtype
    assert_equal "savings", account.accountable.subtype
  end

  test "subtype persists on create when attributes arrive in permit order" do
    Account.any_instance.stubs(:sync_later)

    # Mirrors `account_params`: `permit` yields keys in filter order, so the
    # create hash carries `subtype` before `accountable_type` — the ordering
    # that previously dropped the subtype on create.
    account = Account.create_and_sync({
      family: @family,
      owner: @admin,
      name: "Savings Account",
      balance: 100,
      subtype: "savings",
      currency: "USD",
      accountable_type: "Depository"
    })

    assert account.persisted?
    assert_equal "savings", account.reload.subtype
    assert_equal "savings", account.accountable.subtype
  end

  test "accountable display names expose singular and group contexts" do
    assert_equal "Investment", Investment.singular_display_name
    assert_equal "Investments", Investment.display_name
    assert_equal "Cash", Depository.singular_display_name
    assert_equal "Cash", Depository.display_name
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

  test "subtype falls back to accountable when account subtype is blank" do
    credit_card = CreditCard.create!(subtype: "visa")
    account = @family.accounts.create!(
      owner: @admin,
      name: "Test Card",
      balance: 100,
      currency: "USD",
      accountable: credit_card,
      subtype: nil
    )

    # Simulate older data where subtype lived only on the accountable
    account.update_column(:subtype, nil)
    assert_equal "visa", credit_card.reload.subtype

    reloaded = Account.find(account.id)
    assert_equal "visa", reloaded.subtype
  end

  test "subtype reflects accountable changes without stale cache" do
    investment = Investment.new(subtype: "brokerage")
    account = @family.accounts.create!(
      owner: @admin,
      name: "Test Investment",
      balance: 1000,
      currency: "USD",
      accountable: investment
    )

    # Force the accountable fallback path (no denormalized column value)
    account.update_column(:subtype, nil)

    assert_equal "brokerage", account.subtype

    account.accountable.update!(subtype: "401k")
    assert_equal "401k", account.subtype
  end

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

  test "tax_treatment returns nil for non-HSA depository accounts" do
    # Depository exposes a `tax_treatment` method so HSA cash flips
    # tax-advantaged, but non-HSA subtypes (checking, savings, cd,
    # money_market) return nil. nil still reads as taxable via `taxable?`,
    # and keeps `tax_treatment.present?` false so the header tax badge does
    # not appear on ordinary bank accounts that never displayed it before.
    assert_nil @account.tax_treatment
    assert_nil @account.tax_treatment_label
    assert_not @account.tax_treatment.present?
    assert @account.taxable?
  end

  test "tax_treatment returns nil for accountables that do not implement it" do
    # CreditCard / Loan / Property / OtherAsset / OtherLiability do not
    # implement `tax_treatment`, so the `TaxTreatable#respond_to?` short-
    # circuit still returns nil for them.
    credit_card_account = @family.accounts.create!(
      owner: @admin,
      name: "Test Credit Card",
      balance: 100,
      currency: "USD",
      accountable: CreditCard.new
    )

    assert_nil credit_card_account.tax_treatment
    assert_nil credit_card_account.tax_treatment_label
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

  test "tax_advantaged? returns true for HSA depository accounts" do
    hsa_depository = @family.accounts.create!(
      owner: @admin,
      name: "Fidelity HSA Cash",
      balance: 3_000,
      currency: "USD",
      accountable: Depository.new(subtype: "hsa")
    )

    assert_equal :tax_advantaged, hsa_depository.tax_treatment
    assert hsa_depository.tax_advantaged?
    assert_not hsa_depository.taxable?
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

  test "taxable? returns true for non-HSA depository accounts" do
    # `@account` is the checking depository fixture; `tax_treatment` is
    # `nil` (no subtype override), which `taxable?` reads as true.
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

  test "destroying account moves linked statements to inbox after commit" do
    statement = AccountStatement.create_from_upload!(
      family: @family,
      account: @account,
      file: uploaded_file(filename: "statement.csv", content_type: "text/csv", content: "date,amount\n2024-01-01,1\n")
    )
    statement.update!(match_confidence: 0.8)

    @account.destroy!

    statement.reload
    assert_nil statement.account_id
    assert_equal "unmatched", statement.review_status
    assert_nil statement.match_confidence
  end

  test "rolled back account destroy keeps linked statements unchanged" do
    statement = AccountStatement.create_from_upload!(
      family: @family,
      account: @account,
      file: uploaded_file(filename: "statement.csv", content_type: "text/csv", content: "date,amount\n2024-01-01,1\n")
    )
    statement.update!(match_confidence: 0.8)

    Account.transaction do
      @account.destroy!
      raise ActiveRecord::Rollback
    end

    statement.reload
    assert Account.exists?(@account.id)
    assert_equal @account.id, statement.account_id
    assert_equal "linked", statement.review_status
    assert_equal 0.8.to_d, statement.match_confidence
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

  test "included_in_reports scope excludes accounts marked as exclude_from_reports" do
    included = @family.accounts.create! name: "Included", balance: 100, currency: "USD", accountable: Depository.new
    excluded = @family.accounts.create! name: "Excluded", balance: 200, currency: "USD", accountable: Depository.new, exclude_from_reports: true

    results = @family.accounts.included_in_reports
    assert_includes results, included
    assert_not_includes results, excluded
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

  test "auto_share_with_family grants guests read_only and other members read_write" do
    @family.update!(default_account_sharing: "private")
    guest = users(:empty)
    guest.update_columns(family_id: @family.id, role: "guest")

    account = Account.create_and_sync({
      family: @family,
      owner: @admin,
      name: "Guest Permission Account",
      balance: 100,
      currency: "USD",
      accountable_type: "Depository",
      accountable_attributes: {}
    })

    account.auto_share_with_family!

    assert_equal "read_only", account.account_shares.find_by(user: guest).permission
    assert_equal "read_write", account.account_shares.find_by(user: @member).permission
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

  test "on account destroyed cascade transfer destroyed" do
    outflow_account = @family.accounts.create!({
      owner: @admin,
      name: "test_account_outflow",
      balance: 100,
      currency: "USD",
      accountable_type: "Depository",
      accountable_attributes: {}
    })
    inflow_account = @family.accounts.create!({
      owner: @admin,
      name: "test_account_inflow",
      balance: 100,
      currency: "USD",
      accountable_type: "Depository",
      accountable_attributes: {}
    })

    transfer = create_transfer(
      from_account: outflow_account,
      to_account: inflow_account,
      amount: 50
    )

    outflow_transaction = transfer.outflow_transaction

    outflow_transaction.reload
    assert_equal "funds_movement", outflow_transaction.kind

    inflow_account.destroy!

    assert_raises(ActiveRecord::RecordNotFound) { transfer.reload }

    outflow_transaction.reload
    assert_equal "standard", outflow_transaction.kind
  end
end
