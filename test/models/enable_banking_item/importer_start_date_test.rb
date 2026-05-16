require "test_helper"

class EnableBankingItem::ImporterStartDateTest < ActiveSupport::TestCase
  include ActiveSupport::Testing::TimeHelpers

  setup do
    @family = families(:dylan_family)

    @enable_banking_item = EnableBankingItem.create!(
      family: @family,
      name: "Test EB",
      country_code: "FR",
      application_id: "test_app_id",
      client_certificate: "test_cert",
      session_id: "test_session",
      session_expires_at: 1.day.from_now
    )

    @enable_banking_account = EnableBankingAccount.create!(
      enable_banking_item: @enable_banking_item,
      name: "Compte courant",
      uid: "hash_abc123",
      account_id: "uuid-1234-5678-abcd",
      currency: "EUR"
    )

    @importer = EnableBankingItem::Importer.new(@enable_banking_item, enable_banking_provider: mock())
  end

  test "initial sync clamps old user-configured start date to 120 days" do
    travel_to Time.zone.local(2026, 5, 16, 12, 0, 0) do
      @enable_banking_item.update!(sync_start_date: Date.new(2025, 1, 1))

      start_date = @importer.send(:determine_sync_start_date, @enable_banking_account)

      assert_equal Date.new(2026, 1, 16), start_date
    end
  end

  test "incremental sync clamps stale last sync lookback to 120 days" do
    travel_to Time.zone.local(2026, 5, 16, 12, 0, 0) do
      @enable_banking_account.update!(raw_transactions_payload: [ { transaction_id: "tx_1" } ])

      old_sync = @enable_banking_item.syncs.create!(created_at: 200.days.ago)
      old_sync.update!(status: :completed, completed_at: 180.days.ago)

      start_date = @importer.send(:determine_sync_start_date, @enable_banking_account)

      assert_equal Date.new(2026, 1, 16), start_date
    end
  end

  test "incremental sync still uses 7-day buffer when within allowed window" do
    travel_to Time.zone.local(2026, 5, 16, 12, 0, 0) do
      @enable_banking_account.update!(raw_transactions_payload: [ { transaction_id: "tx_1" } ])

      recent_sync = @enable_banking_item.syncs.create!(created_at: 10.days.ago)
      recent_sync.update!(status: :completed, completed_at: 3.days.ago)

      start_date = @importer.send(:determine_sync_start_date, @enable_banking_account)

      assert_equal Date.new(2026, 5, 6), start_date
    end
  end
end
