# frozen_string_literal: true

require "test_helper"

class BrexAccount::Transactions::ProcessorTest < ActiveSupport::TestCase
  setup do
    @brex_item = brex_items(:one)
    @brex_account = @brex_item.brex_accounts.create!(
      account_id: "cash_unlinked",
      account_kind: "cash",
      name: "Unlinked Cash",
      currency: "USD",
      raw_transactions_payload: [
        {
          id: "tx_skipped",
          amount: { amount: 1_00, currency: "USD" },
          description: "Skipped transaction",
          posted_at_date: "2026-01-02"
        }
      ]
    )
  end

  test "counts intentionally skipped transactions separately from failures" do
    result = BrexAccount::Transactions::Processor.new(@brex_account).process

    assert result[:success]
    assert_equal 1, result[:total]
    assert_equal 0, result[:imported]
    assert_equal 1, result[:skipped]
    assert_equal 0, result[:failed]
    assert_equal "No linked account", result[:skipped_transactions].first[:reason]
    assert_empty result[:errors]
  end

  test "imports linked transactions successfully" do
    link_brex_account!

    result = BrexAccount::Transactions::Processor.new(@brex_account).process

    assert result[:success]
    assert_equal 1, result[:total]
    assert_equal 1, result[:imported]
    assert_equal 0, result[:skipped]
    assert_equal 0, result[:failed]
    assert_empty result[:skipped_transactions]
    assert_empty result[:errors]
  end

  test "aggregates partial transaction failures" do
    link_brex_account!
    @brex_account.update!(
      raw_transactions_payload: [
        {
          id: "tx_success",
          amount: { amount: 1_00, currency: "USD" },
          description: "Successful transaction",
          posted_at_date: "2026-01-02"
        },
        {
          id: "tx_failure",
          amount: { amount: 2_00, currency: "USD" },
          description: "Failed transaction",
          posted_at_date: "not-a-date"
        }
      ]
    )

    result = BrexAccount::Transactions::Processor.new(@brex_account).process

    assert_not result[:success]
    assert_equal 2, result[:total]
    assert_equal 1, result[:imported]
    assert_equal 0, result[:skipped]
    assert_equal 1, result[:failed]
    assert_empty result[:skipped_transactions]
    assert_equal "tx_failure", result[:errors].first[:transaction_id]
    assert_match(/Unable to parse transaction date/, result[:errors].first[:error])
  end

  private

    def link_brex_account!
      account = @brex_item.family.accounts.create!(
        name: "Linked Cash",
        balance: 0,
        currency: "USD",
        accountable: Depository.new
      )
      AccountProvider.create!(account: account, provider: @brex_account)
    end
end
