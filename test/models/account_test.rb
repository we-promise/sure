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

  test "default owner prefers a family admin before a super admin" do
    family = families(:empty)
    admin = users(:empty)
    super_admin = users(:sure_support_staff)

    Current.reset

    account = family.accounts.create!(
      name: "Unowned test account",
      balance: 0,
      currency: "USD",
      accountable: Depository.new
    )

    assert_equal admin, account.owner
    assert_not_equal super_admin, account.owner
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

  test "create_and_sync keeps the entered current balance when it differs from the opening balance" do
    Account.any_instance.stubs(:sync_later)

    account = Account.create_and_sync(
      {
        family: @family,
        owner: @admin,
        name: "Student Loan",
        balance: 8_000,
        currency: "USD",
        accountable_type: "Loan",
        accountable_attributes: { initial_balance: 20_000, rate_type: "fixed", interest_rate: 4.5, term_months: 120 }
      },
      skip_initial_sync: true
    )

    assert_equal 20_000, account.valuations.opening_anchor.first.entry.amount
    # Without a today anchor, the initial sync would walk forward from the
    # opening valuation and overwrite the entered 8,000 with 20,000.
    today_valuation = account.entries.valuations.find_by(date: Date.current)
    assert_not_nil today_valuation
    assert_equal 8_000, today_valuation.amount
  end

  test "create_and_sync leaves the opening anchor alone when the opening balance date is today" do
    Account.any_instance.stubs(:sync_later)

    account = Account.create_and_sync(
      {
        family: @family,
        owner: @admin,
        name: "Student Loan",
        balance: 8_000,
        currency: "USD",
        accountable_type: "Loan",
        accountable_attributes: { initial_balance: 20_000, rate_type: "fixed", interest_rate: 4.5, term_months: 120 }
      },
      skip_initial_sync: true,
      opening_balance_date: Date.current
    )

    # Both balances land on the same day, so today's balance cannot be
    # anchored without reusing (and overwriting) the opening anchor.
    valuations = account.entries.valuations.where(date: Date.current)
    assert_equal 1, valuations.count
    assert_equal 20_000, valuations.first.amount
    assert_equal "opening_anchor", valuations.first.entryable.kind
  end

  test "create_and_sync treats a blank initial balance as absent" do
    Account.any_instance.stubs(:sync_later)

    account = Account.create_and_sync(
      {
        family: @family,
        owner: @admin,
        name: "Student Loan",
        balance: 8_000,
        currency: "USD",
        accountable_type: "Loan",
        accountable_attributes: { initial_balance: "", rate_type: "fixed", interest_rate: 4.5, term_months: 120 }
      },
      skip_initial_sync: true
    )

    assert_equal 8_000, account.valuations.opening_anchor.first.entry.amount
    assert_nil account.entries.valuations.find_by(date: Date.current)
  end

  test "create_and_sync treats a zero initial balance as a real opening balance" do
    Account.any_instance.stubs(:sync_later)

    account = Account.create_and_sync(
      {
        family: @family,
        owner: @admin,
        name: "Student Loan",
        balance: 8_000,
        currency: "USD",
        accountable_type: "Loan",
        accountable_attributes: { initial_balance: 0, rate_type: "fixed", interest_rate: 4.5, term_months: 120 }
      },
      skip_initial_sync: true
    )

    assert_equal 0, account.valuations.opening_anchor.first.entry.amount
    assert_equal 8_000, account.entries.valuations.find_by(date: Date.current)&.amount
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

  # Logo URL tests
  test "logo_url returns Brandfetch URL when configured" do
    Setting.stubs(:brand_fetch_client_id).returns("test_client_id")
    Setting.stubs(:brand_fetch_logo_size).returns(120)
    @account.institution_domain = "example.com"

    expected_url = "https://cdn.brandfetch.io/example.com/icon/fallback/lettermark/w/120/h/120?c=test_client_id"
    assert_equal expected_url, @account.logo_url
  end

  test "logo_url returns DuckDuckGo favicon when Brandfetch not configured" do
    Setting.stubs(:brand_fetch_client_id).returns(nil)
    @account.institution_domain = "example.com"

    expected_url = "https://icons.duckduckgo.com/ip3/example.com.ico"
    assert_equal expected_url, @account.logo_url
  end

  test "logo_url returns provider logo when available" do
    Setting.stubs(:brand_fetch_client_id).returns(nil)
    @account.institution_domain = nil
    provider = OpenStruct.new(logo_url: "https://provider.com/logo.png")
    @account.stubs(:provider).returns(provider)

    assert_equal "https://provider.com/logo.png", @account.logo_url
  end

  test "logo_url prefers provider logo over favicon fallback" do
    Setting.stubs(:brand_fetch_client_id).returns(nil)
    @account.institution_domain = "example.com"
    provider = OpenStruct.new(logo_url: "https://provider.com/logo.png")
    @account.stubs(:provider).returns(provider)

    assert_equal "https://provider.com/logo.png", @account.logo_url
  end

  test "logo_url returns attached logo URL when manual source" do
    Setting.stubs(:brand_fetch_client_id).returns(nil)
    @account.institution_domain = nil
    @account.logo.attach(
      io: StringIO.new("fake-logo"),
      filename: "logo.png",
      content_type: "image/png"
    )
    @account.logo_source = "manual"

    assert @account.logo_url.include?("/rails/active_storage")
  end

  test "logo_url returns nil when no logo source available" do
    Setting.stubs(:brand_fetch_client_id).returns(nil)
    @account.institution_domain = nil
    @account.stubs(:provider).returns(nil)

    assert_nil @account.logo_url
  end

  # Favicon URL tests
  test "favicon_url returns DuckDuckGo URL" do
    @account.institution_domain = "example.com"
    expected_url = "https://icons.duckduckgo.com/ip3/example.com.ico"
    assert_equal expected_url, @account.favicon_url
  end

  test "favicon_url returns nil when no domain" do
    @account.institution_domain = nil
    assert_nil @account.favicon_url
  end

  # Domain cleaning tests
  test "clean_institution_domain removes https://" do
    @account.institution_domain = "https://example.com"
    @account.valid?
    assert_equal "example.com", @account.institution_domain
  end

  test "clean_institution_domain removes www." do
    @account.institution_domain = "www.example.com"
    @account.valid?
    assert_equal "example.com", @account.institution_domain
  end

  test "clean_institution_domain removes path" do
    @account.institution_domain = "example.com/some/path"
    @account.valid?
    assert_equal "example.com", @account.institution_domain
  end

  test "clean_institution_domain removes port" do
    @account.institution_domain = "example.com:8080"
    @account.valid?
    assert_equal "example.com", @account.institution_domain
  end

  test "clean_institution_domain handles complex URLs" do
    @account.institution_domain = "https://www.example.com:8080/some/path"
    @account.valid?
    assert_equal "example.com", @account.institution_domain
  end

  # Logo source enum tests
  test "logo_source defaults to auto" do
    assert_equal "auto", @account.logo_source
  end

  test "logo_source can be set to manual" do
    @account.logo_source = "manual"
    assert_equal "manual", @account.logo_source
  end

  test "logo_source is auto?" do
    assert @account.logo_source_auto?
  end

  test "logo_source is manual?" do
    @account.logo_source = "manual"
    assert @account.logo_source_manual?
  end

  test "uploading a logo without an explicit logo_source marks it manual" do
    # Simulates a caller that submits a logo without choosing a source. The
    # enum defaults logo_source to "auto", which previously swallowed
    # set_logo_source and later let FetchLogoJob replace the upload with an
    # institution logo.
    @account.update!(
      logo: { io: StringIO.new("user-upload"), filename: "logo.png", content_type: "image/png" }
    )

    assert @account.logo_source_manual?
  end

  test "saving without an upload leaves an existing logo_source untouched" do
    # The auto fetcher attaches through attach_fetched_logo, so a plain save
    # on an account with a fetched logo must not flip it to manual.
    @account.attach_fetched_logo(
      io: StringIO.new("fetched-logo"),
      filename: "fetched.png",
      content_type: "image/png"
    )
    @account.reload

    @account.update!(notes: "changed")

    assert @account.logo_source_auto?
  end

  test "rejects logo uploads with non-image content types" do
    # The form's accept="image/*" is client-side only; a crafted request can
    # submit anything, so the model enforces the content type too.
    @account.logo.attach(
      io: StringIO.new("<html><body>not an image</body></html>"),
      filename: "page.html",
      content_type: "text/html"
    )

    assert_not @account.valid?
    assert @account.errors[:logo].present?
  end

  test "rejects logo uploads larger than the size limit" do
    @account.logo.attach(
      io: StringIO.new("x" * (Account::MAX_LOGO_BYTES + 1)),
      filename: "huge.png",
      content_type: "image/png"
    )

    assert_not @account.valid?
    assert @account.errors[:logo].present?
  end

  test "accepts logo uploads with an image content type" do
    @account.logo.attach(
      io: StringIO.new("valid-image"),
      filename: "logo.png",
      content_type: "image/png"
    )

    assert @account.valid?
  end

  test "changing the domain purges the previously fetched logo" do
    @account.update!(institution_domain: "old.example.com", logo_source: "auto")
    @account.attach_fetched_logo(
      io: StringIO.new("old-logo"),
      filename: "old.png",
      content_type: "image/png"
    )
    @account.reload
    assert @account.logo.attached?

    @account.update!(institution_domain: "new.example.com")

    assert_not @account.reload.logo.attached?
  end

  test "a failed fetch after a domain change serves the new domain fallback, not the old logo" do
    Setting.stubs(:brand_fetch_client_id).returns(nil)

    @account.update!(institution_domain: "old.example.com", logo_source: "auto")
    @account.attach_fetched_logo(
      io: StringIO.new("old-logo"),
      filename: "old.png",
      content_type: "image/png"
    )

    # Mock DNS resolution for DuckDuckGo
    Resolv.stubs(:getaddresses).with("icons.duckduckgo.com").returns([ "52.149.246.247" ])

    ddg_failure = Net::HTTPNotFound.new("1.1", "404", "Not Found")
    ddg_failure.stubs(:body).returns(nil)
    ddg_http = mock
    ddg_http.stubs(:use_ssl=)
    ddg_http.stubs(:open_timeout=)
    ddg_http.stubs(:read_timeout=)
    ddg_http.expects(:request).returns(ddg_failure)
    Net::HTTP.stubs(:new).with("icons.duckduckgo.com", 443).returns(ddg_http)

    @account.update!(institution_domain: "new.example.com")
    FetchLogoJob.perform_now(@account.id, "new.example.com")

    assert_not @account.logo.attached?
    assert_equal "https://icons.duckduckgo.com/ip3/new.example.com.ico", @account.logo_url
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

  test "cleanup transfers preloads transaction associations" do
    counterparty = @family.accounts.create!(
      owner: @admin,
      name: "Transfer counterparty",
      balance: 100,
      currency: "USD",
      accountable: Depository.new
    )
    transfers = 3.times.map do |index|
      create_transfer(
        from_account: @account,
        to_account: counterparty,
        amount: 10 + index
      )
    end

    queries = capture_sql_queries { @account.send(:cleanup_transfers) }

    assert_empty queries.grep(/SELECT "transactions"\.\* FROM "transactions" WHERE "transactions"\."id" =/)
    assert transfers.all? { |transfer| !Transfer.exists?(transfer.id) }
  end

  test "manual logo source displays the attached logo" do
    # When logo_source is "manual", the uploaded logo should be displayed
    logo_file = uploaded_file(filename: "test_logo.png", content_type: "image/png", content: "valid-image-data")

    account = Account.create_and_sync(
      {
        family: @family,
        owner: @admin,
        name: "Test8",
        balance: 1000,
        currency: "USD",
        accountable_type: "Depository",
        accountable_attributes: {},
        logo: logo_file,
        logo_source: "manual"
      },
      skip_initial_sync: true
    )

    assert account.persisted?, "Account should be created successfully"
    assert account.logo.attached?, "Logo should be attached to the account"
    assert account.logo_source_manual?, "Logo source should be manual"

    # logo_url should return the attached logo URL
    logo_url = account.logo_url
    assert logo_url.present?, "logo_url should be present when logo is attached with manual source"

    # Verify it's the blob URL
    assert logo_url.include?("/rails/active_storage/"), "logo_url should be an Active Storage blob URL"
  end

  test "auto logo source uses an attached fetched logo" do
    # When logo_source is "auto", a logo successfully attached by LogoFetcher
    # should be served before falling back to remote logo providers.
    logo_file = uploaded_file(
      filename: "test_logo.png",
      content_type: "image/png",
      content: "valid-image-data"
    )

    account = Account.create_and_sync(
      {
        family: @family,
        owner: @admin,
        name: "Test Auto Account",
        balance: 1000,
        currency: "USD",
        accountable_type: "Depository",
        accountable_attributes: {},
        institution_domain: "example.com",
        logo: logo_file,
        logo_source: "auto"
      },
      skip_initial_sync: true
    )

    assert account.persisted?, "Account should be created successfully"
    assert account.logo.attached?, "Logo should be attached to the account"
    assert account.logo_source_auto?, "Logo source should be auto"

    # An attached fetched logo should take priority over remote fallbacks.
    logo_url = account.logo_url

    assert logo_url.present?, "logo_url should be present"
    assert logo_url.include?("/rails/active_storage/"),
      "logo_url should be the attached blob URL"
  end

  test "manual logo source falls back to auto-fetch when no logo attached" do
    # When logo_source is "manual" but no logo is attached, should fallback
    account = Account.create_and_sync(
      {
        family: @family,
        owner: @admin,
        name: "Test Manual No Logo",
        balance: 1000,
        currency: "USD",
        accountable_type: "Depository",
        accountable_attributes: {},
        institution_domain: "example.com",
        logo_source: "manual"
      },
      skip_initial_sync: true
    )

    assert account.persisted?, "Account should be created successfully"
    assert_not account.logo.attached?, "Logo should not be attached"
    assert account.logo_source_manual?, "Logo source should be manual"

    # logo_url should return the auto-fetch fallback
    logo_url = account.logo_url
    assert logo_url.present?, "logo_url should be present even without attached logo"
  end

  test "clean_institution_domain removes uppercase https scheme" do
    @account.institution_domain = "HTTPS://WWW.EXAMPLE.COM/path"
    @account.valid?
    assert_equal "example.com", @account.institution_domain
  end
end
