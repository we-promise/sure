require "test_helper"

class EmailAlertMessage::ProcessorTest < ActiveSupport::TestCase
  include EmailAlertsTestHelper

  setup do
    stub_dkim_dns!
    @item = email_alert_items(:one)
    @account = @item.family.accounts.create!(name: "GTBank", balance: 0, currency: "NGN", accountable: Depository.new)
  end

  test "imports a verified alert into the linked account" do
    link("gtbank:4821")
    message = receive("gtbank_credit")

    assert_difference -> { @account.entries.count }, 1 do
      message.process!
    end

    assert message.reload.processed?
    entry = @account.entries.order(:created_at).last
    assert_equal BigDecimal("-250000"), entry.amount
    assert_equal "NGN", entry.currency
    assert_equal Date.new(2026, 11, 19), entry.date
    assert_equal "email_alert", entry.source
    assert_match(/\Agtbank_/, entry.external_id)
    assert_equal "00001226111915154200", entry.entryable.extra.dig("email_alert", "reference")

    provider_account = message.email_alert_account
    assert_equal BigDecimal("312450.75"), provider_account.current_balance
  end

  test "redelivered alerts are stored and imported once" do
    link("gtbank:4821")

    first = receive("gtbank_credit")
    second = receive("gtbank_credit")
    assert_equal first, second

    assert_difference -> { @account.entries.count }, 1 do
      first.process!
      EmailAlertMessage::Processor.new(first.reload).process
    end
  end

  test "fee alerts are categorized as fees" do
    link("gtbank:4821")
    receive("gtbank_debit_commission").process!

    entry = @account.entries.order(:created_at).last
    assert_equal BigDecimal("25"), entry.amount
    assert_equal I18n.t(Category::FEES_NAME_KEY), entry.entryable.category&.name
  end

  test "alerts for an unlinked account wait and import once it is linked" do
    message = receive("opay_transfer")
    message.process!

    assert message.reload.awaiting_link?
    provider_account = @item.email_alert_accounts.find_by!(email_alert_account_id: "opay:wallet")
    assert_equal "OPay", provider_account.name
    assert_equal "NGN", provider_account.currency

    provider_account.ensure_account_provider!(@account)
    assert_difference -> { @account.entries.count }, 1 do
      @item.import_latest_email_alert_data
    end
    assert message.reload.processed?
  end

  test "rejects alerts whose DKIM signature does not verify" do
    message = receive("gtbank_credit", raw: email_alert_fixture("gtbank_credit").sub("250000", "950000"))
    message.process!

    assert message.reload.rejected?
    assert_match(/DKIM verification failed/, message.processing_error)
    assert_empty @item.email_alert_accounts
  end

  test "a failed DNS key lookup is retried later rather than rejected" do
    EmailAlert::DkimVerifier::KeyResolver.any_instance.unstub(:call)
    EmailAlert::DkimVerifier::KeyResolver.any_instance.stubs(:call).returns(nil)

    message = receive("grey_card")
    message.process!

    assert message.reload.failed?
    assert_includes EmailAlertMessage.retryable, message
  end

  test "mail from a bank that is not a transaction is ignored" do
    message = receive("opay_otp")
    message.process!

    assert message.reload.ignored?
    assert_empty @item.email_alert_accounts
  end

  test "an older alert does not replace a newer balance" do
    link("gtbank:4821")
    receive("gtbank_credit").process!          # 2026-11-19, balance 312,450.75
    receive("gtbank_debit_commission").process! # 2026-11-17, balance 41,210.50

    provider_account = @item.email_alert_accounts.find_by!(email_alert_account_id: "gtbank:4821")
    assert_equal BigDecimal("312450.75"), provider_account.current_balance
  end

  private

    def receive(name, raw: email_alert_fixture(name))
      EmailAlertMessage.receive!(@item, raw)
    end

    def link(key)
      provider_account = @item.email_alert_accounts.create!(email_alert_account_id: key, name: key, currency: "NGN")
      provider_account.ensure_account_provider!(@account)
    end
end
