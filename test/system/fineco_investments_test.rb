require "application_system_test_case"

class FinecoInvestmentsTest < ApplicationSystemTestCase
  setup do
    Current.reset
    ActiveRecordEncryptionConfig.stubs(:explicitly_configured?).returns(true)
    Provider::Fineco.stubs(:verified_identity_contract?).returns(true)
    @user = users(:family_admin)
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))

    @item = FinecoItem.new(
      family: @user.family,
      owner: @user,
      gsessionid: "synthetic-session-cookie",
      account_index: "2",
      dossier_index: "4",
      captured_at: Time.current,
      bank_account_number: "SYNTHETIC-ACCOUNT-2",
      dossier_identity: Digest::SHA256.hexdigest("synthetic-dossier")
    )
    @item.import_portfolio_snapshot!(payload: portfolio_payload, captured_at: Time.current)
  end

  teardown do
    Current.reset
  end

  test "renders the native Fineco Investment account and snapshot guidance" do
    with_self_hosting do
      sign_in @user
      visit accounts_path
    end

    within "#fineco_item_#{@item.id}" do
      assert_text "FinecoBank"
      assert_text "Fineco investments"
      assert_text I18n.t("fineco_items.card.snapshot_scope")
      click_link "Fineco investments"
    end

    assert_current_path account_path(@item.accounts.sole)
    click_on I18n.t("accounts.show.tabs.holdings")
    assert_text "Synthetic fund"
  end

  private

    def portfolio_payload
      position = {
        "instrId" => "US0000000002",
        "venueSystem" => "XETRA",
        "symbol" => "SYNTH",
        "description" => "Synthetic fund",
        "type" => "etf",
        "currencyCd" => "EUR",
        "qty" => "2",
        "avgPrice" => "45",
        "marketPrice" => "50",
        "bookValue" => "90",
        "marketValue" => "100",
        "profitLoss" => "10",
        "accrual" => "0.5",
        "ongoingAccrual" => "0.25"
      }
      summary = {
        "currencyCd" => "EUR",
        "bookValue" => "90",
        "marketValue" => "100",
        "profitLoss" => "10",
        "profitLossPerc" => "11.11",
        "accrual" => "0.5"
      }

      {
        "info" => { "dossier" => { "blocked" => false } },
        "filters" => {
          "currencies" => { "total" => [ "EUR" ], "show" => [ "EUR" ] },
          "instrumentTypes" => { "total" => [ "etf" ], "show" => [ "etf" ] }
        },
        "positions" => { "show" => [ position ] },
        "summary" => { "show" => summary, "total" => summary }
      }
    end
end
