require "test_helper"

class CreditCardsControllerTest < ActionDispatch::IntegrationTest
  include AccountableResourceInterfaceTest

  setup do
    sign_in @user = users(:family_admin)
    @account = accounts(:credit_card)
  end

  test "creates with credit card details" do
    assert_difference -> { Account.count } => 1,
      -> { CreditCard.count } => 1,
      -> { Valuation.count } => 1,
      -> { Entry.count } => 1 do
      post credit_cards_path, params: {
        account: {
          name: "New Credit Card",
          balance: 1000,
          currency: "USD",
          institution_name: "Amex",
          institution_domain: "americanexpress.com",
          notes: "Primary card",
          accountable_type: "CreditCard",
          accountable_attributes: {
            available_credit: 5000,
            minimum_payment: 25.51,
            apr: 15.99,
            expiration_date: 2.years.from_now.to_date,
            annual_fee: 99
          }
        }
      }
    end

    created_account = Account.order(:created_at).last

    assert_equal "New Credit Card", created_account.name
    assert_equal 1000, created_account.balance
    assert_equal "USD", created_account.currency
    assert_equal "Amex", created_account[:institution_name]
    assert_equal "americanexpress.com", created_account[:institution_domain]
    assert_equal "Primary card", created_account[:notes]
    assert_equal 5000, created_account.accountable.available_credit
    assert_equal 25.51, created_account.accountable.minimum_payment
    assert_equal 15.99, created_account.accountable.apr
    assert_equal 2.years.from_now.to_date, created_account.accountable.expiration_date
    assert_equal 99, created_account.accountable.annual_fee

    assert_redirected_to created_account
    assert_equal "Credit card account created", flash[:notice]
    assert_enqueued_with(job: SyncJob)
  end

  test "updates with credit card details" do
    assert_no_difference [ "Account.count", "CreditCard.count" ] do
      patch credit_card_path(@account), params: {
        account: {
          name: "Updated Credit Card",
          balance: 2000,
          currency: "USD",
          institution_name: "Chase",
          institution_domain: "chase.com",
          notes: "Updated notes",
          accountable_type: "CreditCard",
          accountable_attributes: {
            id: @account.accountable_id,
            available_credit: 6000,
            minimum_payment: 50,
            apr: 14.99,
            expiration_date: 3.years.from_now.to_date,
            annual_fee: 0
          }
        }
      }
    end

    @account.reload

    assert_equal "Updated Credit Card", @account.name
    assert_equal 2000, @account.balance
    assert_equal "Chase", @account[:institution_name]
    assert_equal "chase.com", @account[:institution_domain]
    assert_equal "Updated notes", @account[:notes]
    assert_equal 6000, @account.accountable.available_credit
    assert_equal 50, @account.accountable.minimum_payment
    assert_equal 14.99, @account.accountable.apr
    assert_equal 3.years.from_now.to_date, @account.accountable.expiration_date
    assert_equal 0, @account.accountable.annual_fee

    assert_redirected_to @account
    assert_equal "Credit card account updated", flash[:notice]
    assert_enqueued_with(job: SyncJob)
  end

  test "updates enable banking balance interpretation flag when linked" do
    enable_banking_account = create_linked_enable_banking_account

    get edit_credit_card_path(@account)
    assert_response :success
    assert_match "treat_balance_as_available_credit", response.body
    assert_match I18n.t("credit_cards.form.treat_balance_as_available_credit_label"), response.body

    patch credit_card_path(@account), params: {
      account: {
        name: @account.name,
        accountable_type: "CreditCard",
        enable_banking: { treat_balance_as_available_credit: "1" }
      }
    }

    assert_redirected_to @account
    assert enable_banking_account.reload.treat_balance_as_available_credit?
  end

  test "clears enable banking balance interpretation flag when toggled off" do
    enable_banking_account = create_linked_enable_banking_account
    enable_banking_account.update!(treat_balance_as_available_credit: true)

    patch credit_card_path(@account), params: {
      account: {
        name: @account.name,
        accountable_type: "CreditCard",
        enable_banking: { treat_balance_as_available_credit: "0" }
      }
    }

    assert_redirected_to @account
    assert_not enable_banking_account.reload.treat_balance_as_available_credit?
  end

  test "ignores enable banking params for accounts without an enable banking link" do
    patch credit_card_path(@account), params: {
      account: {
        name: "Still works",
        accountable_type: "CreditCard",
        enable_banking: { treat_balance_as_available_credit: "1" }
      }
    }

    assert_redirected_to @account
    assert_equal "Still works", @account.reload.name
  end

  private
    def create_linked_enable_banking_account
      enable_banking_item = EnableBankingItem.create!(
        family: @account.family,
        name: "Test EB",
        country_code: "FR",
        application_id: "app_id",
        client_certificate: "cert"
      )
      enable_banking_account = EnableBankingAccount.create!(
        enable_banking_item: enable_banking_item,
        name: "Linked card",
        uid: "hash_cc",
        currency: "EUR",
        current_balance: 900.00,
        credit_limit: 1000.00
      )
      AccountProvider.create!(account: @account, provider: enable_banking_account)
      enable_banking_account
    end
end
