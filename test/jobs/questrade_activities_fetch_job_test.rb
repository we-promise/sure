require "test_helper"

class QuestradeActivitiesFetchJobTest < ActiveJob::TestCase
  setup do
    @family = families(:empty)
    questrade_item = @family.questrade_items.create!(name: "Test", refresh_token: "dummy-token")
    @questrade_account = questrade_item.questrade_accounts.create!(
      questrade_account_id: "53999999", name: "TFSA (53999999)", currency: "CAD", current_balance: 1500
    )
    @account = @family.accounts.create!(name: "TFSA", balance: 0, currency: @family.currency, accountable: Investment.new)
    @questrade_account.ensure_account_provider!(@account)
    @questrade_account.reload

    @provider = mock("questrade_provider")
    QuestradeItem.any_instance.stubs(:questrade_provider).returns(@provider)
    Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)
  end

  test "activities imported after the sync reach the cached exchange rate notes" do
    assert_empty @family.currencies_without_exchange_rate
    @provider.expects(:get_activities).returns([
      { "type" => "Dividends", "action" => "DIV", "netAmount" => 12.5, "currency" => "SEK",
        "transactionDate" => Date.current.to_s, "description" => "Stockholm dividend" }
    ])

    QuestradeActivitiesFetchJob.perform_now(@questrade_account)

    assert @account.entries.where(currency: "SEK").exists?
    assert_equal %w[SEK], Family.find(@family.id).currencies_without_exchange_rate
  end

  test "a fetch that imports nothing and retries leaves sync activity alone" do
    @provider.expects(:get_activities).returns([])

    assert_no_changes -> { @family.reload.latest_sync_activity_at } do
      assert_enqueued_with(job: QuestradeActivitiesFetchJob) do
        QuestradeActivitiesFetchJob.perform_now(@questrade_account)
      end
    end
  end
end
