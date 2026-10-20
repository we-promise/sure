require "test_helper"

class UI::Account::BankBalancesTest < ViewComponent::TestCase
  BankItemStub = Struct.new(:family_id)
  ProviderAccountStub = Struct.new(:currency, :enable_banking_item, :balance_snapshot)
  AccountProviderStub = Struct.new(:provider_type, :provider)
  AccountStub = Struct.new(
    :accountable_type,
    :currency,
    :family_id,
    :account_providers,
    :updated_at,
    keyword_init: true
  )

  class AccountProvidersStub
    def initialize(provider)
      @provider = provider
    end

    def find_by(provider_type:)
      return unless provider_type == "EnableBankingAccount" && @provider

      AccountProviderStub.new("EnableBankingAccount", @provider)
    end
  end

  test "renders source bank balances with currency, source type, reference date and fetched time" do
    fetched_at = Time.zone.local(2026, 10, 18, 9, 15)
    reference_date = Date.new(2026, 10, 17)
    last_changed_at = Time.zone.local(2026, 10, 17, 8, 30)
    payload = snapshot_payload(
      booked: balance_payload(
        amount: "1250.50",
        source_type: "closingBooked",
        reference_date: reference_date,
        last_changed_at: last_changed_at
      ),
      available: balance_payload(amount: "1180.25", source_type: "interimAvailable"),
      expected: balance_payload(amount: "1190.00", source_type: "expected", reference_date: reference_date),
      fetched_at: fetched_at
    )

    render_inline(UI::Account::BankBalances.new(account: account_with(payload)))

    assert_selector "h2", text: I18n.t("UI.account.bank_balances.title")
    assert_selector "dt", text: I18n.t("UI.account.bank_balances.booked_balance")
    assert_selector "dt", text: I18n.t("UI.account.bank_balances.available_balance")
    assert_selector "dt", text: I18n.t("UI.account.bank_balances.expected_balance")
    assert_text "#{Money.new(BigDecimal("1250.50"), "EUR").format} EUR"
    assert_text "#{Money.new(BigDecimal("1180.25"), "EUR").format} EUR"
    assert_text "#{Money.new(BigDecimal("1190.00"), "EUR").format} EUR"
    assert_text I18n.t("UI.account.bank_balances.source_type", source_type: "closingBooked")
    assert_text I18n.t(
      "UI.account.bank_balances.reference_date",
      date: I18n.l(reference_date, format: :long)
    )
    assert_text I18n.t(
      "UI.account.bank_balances.reference_date",
      date: I18n.t("UI.account.bank_balances.unknown")
    )
    assert_text I18n.t(
      "UI.account.bank_balances.bank_last_changed",
      time: I18n.l(last_changed_at, format: :long)
    )
    assert_text I18n.l(fetched_at, format: :long)
    assert_selector ".privacy-sensitive", text: Money.new(BigDecimal("1250.50"), "EUR").format
    assert_selector ".privacy-sensitive", text: I18n.l(reference_date, format: :long)
    assert_selector ".privacy-sensitive", text: I18n.l(fetched_at, format: :long)
    assert_text I18n.t("UI.account.bank_balances.availability_note")
  end

  test "distinguishes missing balances in a fetched snapshot from a snapshot not fetched yet" do
    fetched_at = Time.zone.local(2026, 10, 18, 9, 15)
    complete_payload = snapshot_payload(fetched_at: fetched_at)

    render_inline(UI::Account::BankBalances.new(account: account_with(complete_payload)))

    assert_selector "dd", text: I18n.t("UI.account.bank_balances.not_provided"), count: 2
    assert_no_selector "dt", text: I18n.t("UI.account.bank_balances.expected_balance")
    assert_text I18n.l(fetched_at, format: :long)

    render_inline(UI::Account::BankBalances.new(account: account_with(nil)))

    assert_selector "dd", text: I18n.t("UI.account.bank_balances.not_fetched_yet"), count: 3
  end

  test "reports failed fetches while retaining saved values and their original fetched time" do
    fetched_at = Time.zone.local(2026, 10, 1, 8, 0)
    attempted_at = Time.zone.local(2026, 10, 19, 20, 45)
    account_updated_at = Time.zone.local(2026, 10, 20, 6, 30)
    reference_date = Date.new(2026, 9, 30)
    payload = snapshot_payload(
      booked: balance_payload(amount: "400.00", source_type: "closingBooked", reference_date: reference_date),
      available: balance_payload(amount: "425.00", source_type: "interimAvailable", reference_date: reference_date),
      fetched_at: fetched_at,
      last_attempted_at: attempted_at,
      status: "failed"
    )

    account = account_with(payload, updated_at: account_updated_at)
    render_inline(UI::Account::BankBalances.new(account: account))

    assert_text I18n.t("UI.account.bank_balances.latest_fetch_failed_with_saved_values")
    assert_text I18n.l(fetched_at, format: :long)
    assert_text I18n.l(attempted_at, format: :long)
    assert_no_text I18n.l(account_updated_at, format: :long)
    assert_text "#{Money.new(BigDecimal("400.00"), "EUR").format} EUR"
  end

  test "explains when an expected balance is used for availability" do
    payload = snapshot_payload(
      available: balance_payload(amount: "95.00", source_type: "XPCD", mapped_from_expected: true),
      fetched_at: Time.zone.local(2026, 10, 18, 9, 15)
    )

    render_inline(UI::Account::BankBalances.new(account: account_with(payload)))

    assert_text I18n.t("UI.account.bank_balances.expected_availability_note")
    assert_text "#{Money.new(BigDecimal("95.00"), "EUR").format} EUR"
    assert_no_selector "dt", text: I18n.t("UI.account.bank_balances.expected_balance")
  end

  test "excludes unsupported account types, currency mismatches and family mismatches" do
    payload = snapshot_payload(fetched_at: Time.zone.local(2026, 10, 18, 9, 15))
    unsupported_types = %w[Investment CreditCard Loan]

    unsupported_types.each do |accountable_type|
      account = account_with(payload, accountable_type: accountable_type)
      render_inline(UI::Account::BankBalances.new(account: account))
      assert_no_selector "h2", text: I18n.t("UI.account.bank_balances.title")
    end

    account = account_with(payload, provider_currency: "USD")
    render_inline(UI::Account::BankBalances.new(account: account))
    assert_no_selector "h2", text: I18n.t("UI.account.bank_balances.title")

    account = account_with(payload, provider_family_id: 2)
    render_inline(UI::Account::BankBalances.new(account: account))
    assert_no_selector "h2", text: I18n.t("UI.account.bank_balances.title")
  end

  test "does not show an old observation after the account currency changes" do
    payload = snapshot_payload(
      booked: balance_payload(amount: "50", source_type: "CLBD", currency: "USD"),
      fetched_at: Time.zone.local(2026, 10, 18, 9, 15)
    )
    render_inline(UI::Account::BankBalances.new(account: account_with(payload)))

    assert_no_text "$50.00"
    assert_no_text "USD"
    assert_selector "dd", text: I18n.t("UI.account.bank_balances.not_provided"), count: 2
  end

  test "fetch times use the current time zone without inventing a bank reference date" do
    payload = snapshot_payload(
      booked: balance_payload(amount: "50", source_type: "CLBD"),
      fetched_at: Time.utc(2026, 10, 20, 16, 37)
    )
    Time.use_zone("Europe/Rome") do
      render_inline(UI::Account::BankBalances.new(account: account_with(payload)))
      assert_text "18:37 (Europe/Rome)"
      assert_text "Bank reference date: Unknown"
    end
  end

  private
    def account_with(snapshot, accountable_type: "Depository", currency: "EUR", provider_currency: currency,
                     family_id: 1, provider_family_id: family_id, updated_at: nil)
      item = BankItemStub.new(provider_family_id)
      provider = ProviderAccountStub.new(provider_currency, item, snapshot)

      AccountStub.new(
        accountable_type: accountable_type,
        currency: currency,
        family_id: family_id,
        account_providers: AccountProvidersStub.new(provider),
        updated_at: updated_at
      )
    end

    def snapshot_payload(
      booked: nil,
      available: nil,
      expected: nil,
      fetched_at: nil,
      last_attempted_at: fetched_at,
      status: "complete"
    )
      {
        "status" => status,
        "fetched_at" => fetched_at&.iso8601(6),
        "last_attempted_at" => last_attempted_at&.iso8601(6),
        "balances" => { "booked" => booked, "available" => available, "expected" => expected }
      }
    end

    def balance_payload(
      amount:,
      source_type:,
      currency: "EUR",
      reference_date: nil,
      last_changed_at: nil,
      mapped_from_expected: false
    )
      {
        "amount" => amount,
        "currency" => currency,
        "source_type" => source_type,
        "reference_date" => reference_date&.iso8601,
        "last_changed_at" => last_changed_at&.iso8601(6),
        "mapped_from_expected" => mapped_from_expected
      }
    end
end
