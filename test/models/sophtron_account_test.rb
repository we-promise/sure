require "test_helper"

class SophtronAccountTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  test "upsert_sophtron_snapshot stores owning item institution metadata fallback" do
    item = families(:dylan_family).sophtron_items.create!(
      name: "Sophtron Connection",
      user_id: "developer-user",
      access_key: Base64.strict_encode64("secret-key"),
      institution_name: "Apple / Goldman Sachs",
      user_institution_id: "ui-apple"
    )

    account = item.sophtron_accounts.build
    account.upsert_sophtron_snapshot!(
      account_id: "card-1",
      account_name: "Juan",
      currency: "USD",
      balance: "1947.18"
    )

    assert_equal "Apple / Goldman Sachs", account.institution_metadata["name"]
    assert_equal "ui-apple", account.institution_metadata["user_institution_id"]
  end

  test "declares raw payloads as encrypted" do
    skip "Encryption not configured" unless SophtronAccount.encryption_ready?

    encrypted = Array(SophtronAccount.encrypted_attributes).map(&:to_s)
    assert_includes encrypted, "raw_payload"
    assert_includes encrypted, "raw_transactions_payload"
  end

  test "database rejects an unsupported balance sign override" do
    account = build_sophtron_account
    account.balance_sign_override = "unsupported"

    assert_raises ActiveRecord::StatementInvalid do
      account.save!(validate: false)
    end
  end

  test "failed sync scheduling rolls back the override and applied balance" do
    sophtron_account = build_sophtron_account
    account = accounts(:credit_card)
    AccountProvider.create!(account: account, provider: sophtron_account)
    original_balance = account.balance
    original_cash_balance = account.cash_balance
    original_anchor = account.current_anchor_balance
    Account.any_instance.stubs(:sync_later).raises(StandardError, "sync scheduling failed")

    assert_raises StandardError do
      sophtron_account.apply_balance_sign_override!("credit")
    end

    assert_nil sophtron_account.reload.balance_sign_override
    assert_equal original_balance, account.reload.balance
    assert_equal original_cash_balance, account.cash_balance
    assert_equal original_anchor, account.current_anchor_balance
  end

  test "detects the feed convention from the override and the confirmed balance sign" do
    {
      [ nil, 25 ] => nil,
      [ "debt", 25 ] => true,
      [ "debt", -25 ] => false,
      [ "credit", -25 ] => true,
      [ "credit", 25 ] => false,
      [ "debt", 0 ] => nil
    }.each do |(override, balance), expected|
      sophtron_account = build_sophtron_account
      sophtron_account.update!(balance: balance)
      sophtron_account.apply_balance_sign_override!(override)

      if expected.nil?
        assert_nil sophtron_account.reload.lender_signed, "override=#{override.inspect} balance=#{balance}"
      else
        assert_equal expected, sophtron_account.reload.lender_signed, "override=#{override.inspect} balance=#{balance}"
      end
      sophtron_account.destroy!
    end
  end

  test "later balances do not change the detected convention" do
    sophtron_account = build_sophtron_account
    sophtron_account.apply_balance_sign_override!("debt")
    assert sophtron_account.lender_signed

    [ 0, -10, 30 ].each do |balance|
      sophtron_account.update!(balance: balance)
      assert sophtron_account.reload.lender_signed, "balance=#{balance}"
    end
  end

  test "a balance that arrives after an override saved at zero is not trusted until the override is saved again" do
    sophtron_account = build_sophtron_account
    sophtron_account.update!(balance: 0)
    sophtron_account.apply_balance_sign_override!("debt")
    assert_nil sophtron_account.lender_signed

    sophtron_account.update!(balance: -10)
    assert_nil sophtron_account.reload.lender_signed

    sophtron_account.update!(balance: 25)
    sophtron_account.apply_balance_sign_override!("debt")
    assert sophtron_account.reload.lender_signed
  end

  test "changing the override re-detects the convention and automatic clears it" do
    sophtron_account = build_sophtron_account
    sophtron_account.apply_balance_sign_override!("debt")
    assert sophtron_account.lender_signed

    sophtron_account.apply_balance_sign_override!("credit")
    assert_equal false, sophtron_account.lender_signed

    sophtron_account.apply_balance_sign_override!(nil)
    assert_nil sophtron_account.lender_signed
  end

  test "lender_signed? is true only for a lender-signed credit card" do
    Account.any_instance.stubs(:sync_later)
    sophtron_account = build_sophtron_account
    AccountProvider.create!(account: accounts(:credit_card), provider: sophtron_account)
    assert_not sophtron_account.lender_signed?

    sophtron_account.apply_balance_sign_override!("debt")
    assert sophtron_account.lender_signed?
  end

  test "lender_signed? is false for accounts that are not credit cards" do
    sophtron_account = build_sophtron_account
    sophtron_account.apply_balance_sign_override!("debt")
    AccountProvider.create!(account: accounts(:loan), provider: sophtron_account)

    assert_not sophtron_account.lender_signed?
  end

  test "a convention change queues re-signing of the stored transactions" do
    Account.any_instance.stubs(:sync_later)
    sophtron_account = build_sophtron_account
    AccountProvider.create!(account: accounts(:credit_card), provider: sophtron_account)

    assert_enqueued_with(job: SophtronTransactionsReprocessJob, args: [ sophtron_account ]) do
      sophtron_account.apply_balance_sign_override!("debt")
    end
  end

  test "re-saving an unchanged override that detects the convention queues re-signing" do
    sophtron_account = build_sophtron_account
    account = accounts(:credit_card)
    AccountProvider.create!(account: account, provider: sophtron_account)
    sophtron_account.update!(balance: 0)
    Account.any_instance.stubs(:sync_later)
    sophtron_account.apply_balance_sign_override!("debt")
    sophtron_account.update!(balance: 25)

    Account.any_instance.unstub(:sync_later)
    Account.any_instance.expects(:sync_later).once
    assert_enqueued_with(job: SophtronTransactionsReprocessJob) do
      sophtron_account.apply_balance_sign_override!("debt")
    end
    assert sophtron_account.reload.lender_signed
  end

  test "an override that keeps the account-holder convention does not queue re-signing" do
    Account.any_instance.stubs(:sync_later)
    sophtron_account = build_sophtron_account
    AccountProvider.create!(account: accounts(:credit_card), provider: sophtron_account)

    assert_no_enqueued_jobs(only: SophtronTransactionsReprocessJob) do
      sophtron_account.apply_balance_sign_override!("credit")
    end
    assert_equal false, sophtron_account.lender_signed
  end

  test "re-saving an unchanged override with nothing new to detect does nothing" do
    sophtron_account = build_sophtron_account
    AccountProvider.create!(account: accounts(:credit_card), provider: sophtron_account)
    Account.any_instance.stubs(:sync_later)
    sophtron_account.apply_balance_sign_override!("debt")

    Account.any_instance.unstub(:sync_later)
    Account.any_instance.expects(:sync_later).never
    SophtronAccount::Processor.any_instance.expects(:process_account!).never
    assert_no_enqueued_jobs(only: SophtronTransactionsReprocessJob) do
      sophtron_account.apply_balance_sign_override!("debt")
    end
  end

  private
    def build_sophtron_account
      item = families(:dylan_family).sophtron_items.create!(
        name: "Sophtron Connection",
        user_id: "developer-user",
        access_key: Base64.strict_encode64("secret-key")
      )

      item.sophtron_accounts.create!(
        account_id: "card-override",
        name: "Card",
        currency: "USD",
        balance: 25
      )
    end
end
