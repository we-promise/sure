require "test_helper"

class Account::CounterpartyRematcherTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @family = families(:dylan_family)
    @account = accounts(:depository)
    @own_account = accounts(:connected)
    enable_banking_item = EnableBankingItem.create!(
      family: @family,
      name: "Test Enable Banking",
      country_code: "DE",
      application_id: "test_app_id",
      client_certificate: "test_cert"
    )
    @enable_banking_account = EnableBankingAccount.create!(
      enable_banking_item: enable_banking_item,
      name: "Main account",
      uid: "eb_uid_rematch",
      currency: "EUR"
    )
    AccountProvider.create!(account: @account, provider: @enable_banking_account)

    @row = {
      entry_reference: "ref_rematch",
      transaction_id: nil,
      booking_date: Date.current.to_s,
      transaction_amount: { amount: "200.00", currency: "EUR" },
      credit_debit_indicator: "DBIT",
      creditor: { name: "Savings" },
      creditor_account: { iban: "AT611904300234573201" }, # pipelock:ignore IBAN
      status: "BOOK"
    }
    @enable_banking_account.update!(raw_transactions_payload: [ @row ])
    EnableBankingEntry::Processor.new(@row, enable_banking_account: @enable_banking_account).process
    @transaction = @account.entries.find_by!(external_id: "enable_banking_ref_rematch").transaction
  end

  test "links an earlier import once an own account gets the counterparty iban" do
    assert_nil @transaction.counterparty_own_account_id

    @own_account.update!(iban: "AT611904300234573201") # pipelock:ignore IBAN
    Account::CounterpartyRematcher.new(@family).rematch!

    assert_equal @own_account, @transaction.reload.counterparty_own_account
    assert_equal "3201", @transaction.counterparty_iban_last4
  end

  test "drops the link when the own account's iban changes" do
    @transaction.update!(counterparty_own_account: @own_account)

    Account::CounterpartyRematcher.new(@family).rematch!

    assert_nil @transaction.reload.counterparty_own_account_id
    assert_equal "3201", @transaction.counterparty_iban_last4
  end

  test "saving an account iban rematches the family in the background" do
    assert_enqueued_with(job: RematchCounterpartyAccountsJob, args: [ @family ]) do
      @own_account.update!(iban: "AT611904300234573201") # pipelock:ignore IBAN
    end

    perform_enqueued_jobs(only: RematchCounterpartyAccountsJob)
    assert_equal @own_account, @transaction.reload.counterparty_own_account
  end

  test "saving an account without changing its iban does not rematch" do
    assert_no_enqueued_jobs(only: RematchCounterpartyAccountsJob) do
      @own_account.update!(name: "Renamed")
    end
  end
end
