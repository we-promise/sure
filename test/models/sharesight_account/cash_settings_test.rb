require "test_helper"

class SharesightAccount::CashSettingsTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    item = @family.sharesight_items.create!(name: "Sharesight", client_id: "client-id", client_secret: "client-secret")
    @account = @family.accounts.create!(name: "CMC Invest", balance: 0, currency: "AUD", accountable: Investment.new)
    @bank = @family.accounts.create!(name: "Macquarie CMA", balance: 0, currency: "AUD", accountable: Depository.new)
    @sharesight_account = item.sharesight_accounts.create!(name: "Shares", sharesight_account_id: "42", currency: "AUD")
    @sharesight_account.ensure_account_provider!(@account)
  end

  test "the form's settings are normalised" do
    @sharesight_account.assign_cash_settings(
      "cash_mode" => "settlement", "settlement_account_id" => @bank.id, "settlement_starts_on" => "2026-11-03",
      "settlement_window_days" => "", "funding_match_terms" => " CMC Share Transfer, , CMC Markets,CMC Markets ",
      "sync_start_date" => "", "ignored" => "x"
    )

    assert @sharesight_account.save
    assert_equal [ "settlement", @bank, Date.new(2026, 11, 3), 7, [ "CMC Share Transfer", "CMC Markets" ], nil ],
                 [ @sharesight_account.cash_mode, @sharesight_account.settlement_account, @sharesight_account.settlement_starts_on,
                   @sharesight_account.settlement_window_days, @sharesight_account.funding_match_terms, @sharesight_account.sync_start_date ]
    assert @sharesight_account.cash_settings_changed?
  end

  test "each mode needs its account" do
    @sharesight_account.cash_mode = "settlement"
    @sharesight_account.dividend_mode = "other_account"

    assert_not @sharesight_account.valid?
    assert_includes @sharesight_account.errors.full_messages, I18n.t("sharesight_accounts.errors.settlement_account_missing")
    assert_includes @sharesight_account.errors.full_messages, I18n.t("sharesight_accounts.errors.dividend_account_missing")
  end

  test "linked accounts belong to the family and aren't the portfolio's own" do
    stranger = families(:empty).accounts.create!(name: "Not ours", balance: 0, currency: "AUD", accountable: Depository.new)
    @sharesight_account.assign_attributes(funding_account: stranger, dividend_mode: "other_account", dividend_account: @account)

    assert_not @sharesight_account.valid?
    assert_includes @sharesight_account.errors.full_messages, I18n.t("sharesight_accounts.errors.account_not_in_family", name: "Not ours")
    assert_includes @sharesight_account.errors.full_messages, I18n.t("sharesight_accounts.errors.account_is_portfolio", name: "CMC Invest")
  end

  test "a deleted settlement account doesn't stop syncs" do
    @sharesight_account.update!(cash_mode: "settlement", settlement_account: @bank)

    @bank.destroy!
    @sharesight_account.reload

    assert_nil @sharesight_account.settlement_account
    assert @sharesight_account.update(raw_payload: { "id" => 42 }), "an import can still save the portfolio"
    assert_equal SharesightAccount::OUTSIDE, @sharesight_account.trade_destination_on(Date.current)
  end

  test "a cash anchor needs both its amount and date" do
    @sharesight_account.cash_anchor_amount = 2049.29

    assert_not @sharesight_account.valid?
    assert_includes @sharesight_account.errors.full_messages, I18n.t("sharesight_accounts.errors.cash_anchor_incomplete")
  end

  test "where cash and dividends go on a given date" do
    @sharesight_account.assign_attributes(cash_mode: "settlement", settlement_account: @bank, settlement_starts_on: Date.new(2026, 11, 3))

    assert_nil @sharesight_account.trade_destination_on(Date.new(2026, 11, 2))
    assert_equal @bank, @sharesight_account.trade_destination_on(Date.new(2026, 11, 3))
    assert_equal @bank, @sharesight_account.dividend_destination_on(Date.new(2026, 11, 3))

    @sharesight_account.cash_mode = "untracked"
    assert_equal SharesightAccount::OUTSIDE, @sharesight_account.trade_destination_on(Date.new(2026, 1, 1))

    @sharesight_account.dividend_mode = "skip"
    assert_equal :skip, @sharesight_account.dividend_destination_on(Date.new(2026, 1, 1))
  end
end
