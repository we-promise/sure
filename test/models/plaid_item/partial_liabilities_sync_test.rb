require "test_helper"
require "ostruct"

class PlaidItem::PartialLiabilitiesSyncTest < ActiveSupport::TestCase
  setup do
    user = users(:family_admin)
    @item = user.family.plaid_items.create!(
      name: "Synthetic bank", plaid_id: "synthetic-item", access_token: "synthetic-token",
      owner: user, billed_products: %w[transactions liabilities], available_products: []
    )
    @provider = mock("provider")
    @item.stubs(:plaid_provider).returns(@provider)
    @item.stubs(:schedule_account_syncs)
    @provider.stubs(:get_item).returns(OpenStruct.new(item: Plaid::Item.new(
      item_id: "synthetic-item", institution_id: "synthetic-institution",
      billed_products: %w[transactions liabilities], available_products: []
    )))
    @provider.stubs(:get_institution).returns(OpenStruct.new(institution: Plaid::Institution.new(
      institution_id: "synthetic-institution", name: "Synthetic bank", url: "https://example.invalid"
    )))
    @accounts = [
      Plaid::AccountBase.new(account_id: "synthetic-cash", name: "Synthetic cash", type: "depository", subtype: "checking",
        balances: Plaid::AccountBalance.new(current: 100, iso_currency_code: "USD")),
      Plaid::AccountBase.new(account_id: "synthetic-credit", name: "Synthetic credit", type: "credit", subtype: "credit card",
        balances: Plaid::AccountBalance.new(current: 10, iso_currency_code: "USD"))
    ]
    @provider.stubs(:get_item_accounts).returns(OpenStruct.new(accounts: @accounts))
    transactions = @accounts.map.with_index do |account, i|
      Plaid::Transaction.new(account_id: account.account_id, transaction_id: "synthetic-transaction-#{i}",
        amount: 1, date: Date.new(2026, 1, 1), name: "Synthetic purchase", merchant_name: "Synthetic merchant",
        original_description: "Synthetic purchase", iso_currency_code: "USD", pending: false)
    end
    @provider.stubs(:get_transactions).returns(OpenStruct.new(added: transactions, modified: [], removed: [], cursor: "synthetic-cursor"))
    @provider.stubs(:get_item_liabilities).raises(server_error)
    Sentry.stubs(:capture_exception).with { |error| raise error }
  end

  test "a liabilities server failure commits core data and shows a sanitized warning" do
    @provider.expects(:get_item_liabilities).raises(server_error).once

    sync = perform_sync

    assert_equal 2, @item.plaid_accounts.count
    assert_equal "synthetic-cursor", @item.reload.next_cursor
    assert_equal 2, imported_entries.count
    assert_equal 1, sync.sync_stats.fetch("data_warnings")
    assert_equal 0, sync.sync_stats.fetch("total_errors")
    warning = sync.sync_stats.fetch("data_quality_details").sole
    assert_equal "warning", warning.fetch("severity")
    assert_equal "INTERNAL_SERVER_ERROR", warning.fetch("error_code")
    refute_includes warning.to_json, "private-provider-message"
    refute_includes warning.to_json, "private-response-header"
    html = ApplicationController.render(ProviderSyncSummary.new(stats: sync.sync_stats, provider_item: @item), layout: false)
    assert_includes html, "Liabilities details could not be refreshed"
  end

  test "the next normal sync retries liabilities and clears the warning without duplicate entries" do
    first = perform_sync
    ids = imported_entries.pluck(:id).sort
    assert_equal 1, first.sync_stats.fetch("data_warnings")
    @provider.expects(:get_item_liabilities).returns(credit_liabilities).once
    @item.reload

    recovered = perform_sync

    assert_equal ids, imported_entries.pluck(:id).sort
    assert_equal 2, @item.plaid_accounts.count
    assert_equal 0, recovered.sync_stats.fetch("data_warnings")
    assert_empty recovered.sync_stats.fetch("data_quality_details")
    assert_equal 2, @item.plaid_accounts.find_by!(plaid_id: "synthetic-credit").current_account.credit_card.minimum_payment
  end

  test "a partial import preserves loan terms without replaying an old variable rate" do
    @accounts.last.type = "loan"
    @accounts.last.subtype = "mortgage"
    @provider.stubs(:get_item_liabilities).returns(Plaid::LiabilitiesObject.new(credit: [], mortgage: [], student: []))
    perform_sync
    provider_account = @item.plaid_accounts.find_by!(plaid_id: "synthetic-credit")
    loan = provider_account.current_account.loan
    loan.update!(rate_type: "variable", interest_rate: 4.5, start_date: Date.new(2020, 1, 1))
    provider_account.update!(raw_liabilities_payload: { mortgage: { interest_rate: { type: "variable", percentage: 5.2 } } })
    @provider.stubs(:get_item_liabilities).raises(server_error)
    @item.reload

    perform_sync

    assert_empty provider_account.reload.raw_liabilities_payload
    assert_equal 4.5, loan.reload.interest_rate.to_f
    assert_empty loan.variable_rate_schedule || {}
  end

  test "core and programming errors still abort the import" do
    error = Plaid::ApiError.new(code: 500, response_body: { error_code: "INTERNAL_SERVER_ERROR" }.to_json)
    @provider.stubs(:get_transactions).raises(error)
    assert_same error, assert_raises(Plaid::ApiError) { perform_sync }
    assert_equal 0, @item.plaid_accounts.count
    assert_nil @item.reload.next_cursor

    @provider.unstub(:get_transactions)
    @provider.stubs(:get_item_accounts).raises(TypeError, "synthetic programming error")
    assert_raises(TypeError) { perform_sync }
    assert_equal 0, @item.plaid_accounts.count
  end

  private
    def server_error
      Plaid::ApiError.new(code: 500, response_body: {
        error_code: "INTERNAL_SERVER_ERROR", request_id: "synthetic-request",
        error_message: "private-provider-message"
      }.to_json, response_headers: { "synthetic-header" => "private-response-header" })
    end

    def credit_liabilities
      Plaid::LiabilitiesObject.new(credit: [ Plaid::CreditCardLiability.new(
        account_id: "synthetic-credit", minimum_payment_amount: 2, aprs: []
      ) ], mortgage: [], student: [])
    end

    def perform_sync
      sync = @item.syncs.create!(status: :syncing)
      PlaidItem::Syncer.new(@item).perform_sync(sync)
      sync.reload
    end

    def imported_entries
      ids = @item.plaid_accounts.filter_map { |account| account.current_account&.id }
      Entry.where(account_id: ids, entryable_type: "Transaction", source: "plaid")
    end
end
