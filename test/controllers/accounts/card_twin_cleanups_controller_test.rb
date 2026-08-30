require "test_helper"

class Accounts::CardTwinCleanupsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
    @family = @user.family
    @account = accounts(:depository)
    @item = EnableBankingItem.create!(
      family: @family, name: "Test Bank", country_code: "DE", application_id: "app",
      client_certificate: "cert", session_id: "sess", session_expires_at: 1.day.from_now
    )
    @eba = EnableBankingAccount.create!(
      enable_banking_item: @item, name: "Test Account",
      uid: "hash_twin_controller", account_id: "uuid-twin-controller", currency: "EUR"
    )
    AccountProvider.create!(account: @account, provider: @eba)
    setup_pair!
  end

  test "show renders the candidate list" do
    get account_card_twin_cleanup_url(@account)

    assert_response :success
    assert_select "input[type=checkbox][value=?]", orphan_entry.id
  end

  test "create removes the selected candidate and resyncs" do
    Account.any_instance.expects(:sync_later).once

    assert_difference "Entry.count", -1 do
      post account_card_twin_cleanup_url(@account),
           params: { card_twin_cleanup: { entry_ids: [ orphan_entry.id ] } }
    end

    assert_redirected_to account_url(@account)
  end

  test "create ignores ids that are not candidates" do
    Account.any_instance.stubs(:sync_later)
    survivor_id = survivor_entry.id

    assert_no_difference "Entry.count" do
      post account_card_twin_cleanup_url(@account),
           params: { card_twin_cleanup: { entry_ids: [ survivor_id ] } }
    end

    assert Entry.exists?(survivor_id)
  end

  test "create rejects an account the user cannot write to" do
    other_family = families(:empty)
    other_account = Account.create!(
      family: other_family, name: "Someone else's", balance: 0, currency: "USD",
      accountable: Depository.new, status: "active"
    )

    post account_card_twin_cleanup_url(other_account),
         params: { card_twin_cleanup: { entry_ids: [] } }

    assert_response :not_found
  end

  private
    def setup_pair!
      customer = row(code: "CCRD", sub_code: "POSD", ref: "ccrd_1", creditor: "ACME Mktp*K4T9QX2")
      merchant = row(code: "MCRD", sub_code: "UPCT", ref: "mcrd_1", creditor: "ACME Mktp")

      @eba.update!(raw_transactions_payload: [ customer, merchant ])
      EnableBankingAccount::Transactions::Processor.new(@eba).process
      @eba.update!(raw_transactions_payload: [ customer ])
      @eba.reload
    end

    def row(code:, sub_code:, ref:, creditor:, amount: "5.12")
      {
        "entry_reference" => ref,
        "transaction_id" => nil,
        "booking_date" => "2026-02-11",
        "value_date" => "2026-02-11",
        "transaction_amount" => { "amount" => amount, "currency" => "EUR" },
        "credit_debit_indicator" => "DBIT",
        "status" => "BOOK",
        "creditor" => { "name" => creditor },
        "bank_transaction_code" => { "code" => code, "sub_code" => sub_code, "description" => "PMNT" }
      }
    end

    def orphan_entry = @account.entries.find_by!(external_id: "enable_banking_mcrd_1")
    def survivor_entry = @account.entries.find_by!(external_id: "enable_banking_ccrd_1")
end
