require "test_helper"

class SharesightAccountSettingsTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
    @family = @user.family
    @item = @family.sharesight_items.create!(name: "Sharesight", client_id: "client-id", client_secret: "client-secret")
    @account = @family.accounts.create!(name: "CMC Invest", balance: 0, currency: "AUD", owner: @user, accountable: Investment.new)
    @bank = @family.accounts.create!(name: "Macquarie CMA", balance: 0, currency: "AUD", owner: @user, accountable: Depository.new)
    @sharesight_account = @item.sharesight_accounts.create!(name: "Shares", sharesight_account_id: "42", currency: "AUD")
    @sharesight_account.ensure_account_provider!(@account)
  end

  test "the investment form shows the portfolio's cash settings" do
    ensure_tailwind_build

    get edit_investment_url(@account)

    assert_response :success
    assert_select "select[name=?]", "account[sharesight][cash_mode]"
    assert_select "select[name=?] option", "account[sharesight][settlement_account_id]", text: "Macquarie CMA"
  end

  test "saving the settings stores them and syncs the portfolio" do
    assert_difference -> { @item.syncs.count }, 1 do
      patch investment_url(@account), params: { account: { name: "CMC Invest", sharesight: {
        cash_mode: "settlement", settlement_account_id: @bank.id, settlement_starts_on: "2026-11-03",
        settlement_window_days: "5", dividend_mode: "with_cash", funding_match_terms: "CMC Share Transfer, CMC Markets"
      } } }
    end

    @sharesight_account.reload
    assert_equal [ "settlement", @bank, Date.new(2026, 11, 3), 5, [ "CMC Share Transfer", "CMC Markets" ] ],
                 [ @sharesight_account.cash_mode, @sharesight_account.settlement_account, @sharesight_account.settlement_starts_on,
                   @sharesight_account.settlement_window_days, @sharesight_account.funding_match_terms ]
  end

  test "an account the user can't write to is refused" do
    private_account = @family.accounts.create!(name: "Not mine", balance: 0, currency: "AUD", owner: users(:family_member), accountable: Depository.new)

    patch investment_url(@account), params: { account: { name: "CMC Invest", sharesight: { cash_mode: "settlement", settlement_account_id: private_account.id } } }

    assert_equal I18n.t("accounts.not_authorized"), flash[:alert]
    assert_equal "broker", @sharesight_account.reload.cash_mode
  end

  test "invalid settings are explained and not saved" do
    patch investment_url(@account), params: { account: { name: "CMC Invest", sharesight: { cash_mode: "settlement", settlement_account_id: "" } } }

    assert_equal I18n.t("sharesight_accounts.errors.settlement_account_missing"), flash[:alert]
    assert_equal "broker", @sharesight_account.reload.cash_mode
  end
end
