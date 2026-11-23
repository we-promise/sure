require "test_helper"

class EmailAlertAccount::ProcessorTest < ActiveSupport::TestCase
  setup do
    @item = email_alert_items(:one)
    @provider_account = @item.email_alert_accounts.create!(
      email_alert_account_id: "gtbank:4821", name: "GTBank ••4821", currency: "NGN",
      current_balance: 312_450.75, balance_as_of: Time.utc(2026, 11, 19, 14, 15)
    )
    @account = @item.family.accounts.create!(name: "GTBank", balance: 0, currency: "NGN", accountable: Depository.new)
    @provider_account.ensure_account_provider!(@account)
  end

  test "anchors the latest alert balance on the alert's date" do
    @account.expects(:set_current_balance).with(BigDecimal("312450.75"), date: Date.new(2026, 11, 19), schedule_sync: false)
    @provider_account.stubs(:current_account).returns(@account)

    assert_equal({ balance_anchored: true }, EmailAlertAccount::Processor.new(@provider_account).process)
  end

  test "leaves the balance alone when no alert reported one" do
    @provider_account.update!(current_balance: nil, balance_as_of: nil)
    @account.expects(:set_current_balance).never
    @provider_account.stubs(:current_account).returns(@account)

    assert_equal({ balance_anchored: false }, EmailAlertAccount::Processor.new(@provider_account).process)
  end

  test "does nothing for an unlinked account" do
    @provider_account.account_provider.destroy!

    assert_nil EmailAlertAccount::Processor.new(@provider_account.reload).process
  end
end
