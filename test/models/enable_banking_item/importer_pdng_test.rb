require "test_helper"

class EnableBankingItem::ImporterPdngTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @account = accounts(:depository)

    @enable_banking_item = EnableBankingItem.create!(
      family: @family,
      name: "Test EB",
      country_code: "FR",
      application_id: "test_app_id",
      client_certificate: "test_cert",
      session_id: "test_session",
      session_expires_at: 1.day.from_now,
      sync_start_date: Date.new(2026, 3, 1)
    )
    @enable_banking_account = EnableBankingAccount.create!(
      enable_banking_item: @enable_banking_item,
      name: "Compte courant",
      uid: "hash_abc123",
      account_id: "uuid-1234-5678-abcd",
      currency: "EUR"
    )
    AccountProvider.create!(account: @account, provider: @enable_banking_account)

    @mock_provider = mock()
    @importer = EnableBankingItem::Importer.new(@enable_banking_item, enable_banking_provider: @mock_provider)
  end

  # --- Post-fetch date filtering ---

  test "filters out transactions before sync_start_date" do
    old_tx = {
      entry_reference: "old_ref",
      transaction_id: nil,
      booking_date: "2024-01-15",  # Before sync_start_date of 2026-03-01
      transaction_amount: { amount: "50.00", currency: "EUR" },
      credit_debit_indicator: "DBIT",
      status: "BOOK"
    }
    recent_tx = {
      entry_reference: "recent_ref",
      transaction_id: nil,
      booking_date: "2026-03-10",
      transaction_amount: { amount: "30.00", currency: "EUR" },
      credit_debit_indicator: "DBIT",
      status: "BOOK"
    }

    result = @importer.send(:filter_transactions_by_date, [ old_tx, recent_tx ], Date.new(2026, 3, 1))

    assert_equal 1, result.count
    assert_equal "recent_ref", result.first[:entry_reference]
  end

  test "uses value_date when booking_date is absent for filtering" do
    tx_only_value_date = {
      entry_reference: "vd_ref",
      transaction_id: nil,
      value_date: "2024-06-01",  # Before sync_start_date
      transaction_amount: { amount: "10.00", currency: "EUR" },
      credit_debit_indicator: "DBIT",
      status: "BOOK"
    }

    result = @importer.send(:filter_transactions_by_date, [ tx_only_value_date ], Date.new(2026, 3, 1))

    assert_equal 0, result.count
  end

  test "keeps transactions with no date (cannot determine, keep to avoid data loss)" do
    tx_no_date = {
      entry_reference: "nodate_ref",
      transaction_id: nil,
      transaction_amount: { amount: "10.00", currency: "EUR" },
      credit_debit_indicator: "DBIT",
      status: "BOOK"
    }

    result = @importer.send(:filter_transactions_by_date, [ tx_no_date ], Date.new(2026, 3, 1))

    assert_equal 1, result.count
  end

  test "keeps transactions on exactly sync_start_date" do
    boundary_tx = {
      entry_reference: "boundary_ref",
      transaction_id: nil,
      booking_date: "2026-03-01",  # Exactly on sync_start_date
      transaction_amount: { amount: "10.00", currency: "EUR" },
      credit_debit_indicator: "DBIT",
      status: "BOOK"
    }

    result = @importer.send(:filter_transactions_by_date, [ boundary_tx ], Date.new(2026, 3, 1))

    assert_equal 1, result.count
  end

  # --- PDNG transaction tagging ---

  test "tags PDNG transactions with pending: true in extra" do
    pdng_tx = {
      entry_reference: "pdng_ref",
      transaction_id: "pdng_txn",
      booking_date: Date.current.to_s,
      transaction_amount: { amount: "20.00", currency: "EUR" },
      credit_debit_indicator: "DBIT",
      status: "PDNG"
    }

    result = @importer.send(:tag_as_pending, [ pdng_tx ])

    assert_equal true, result.first[:_pending]
  end

  test "tags all passed transactions regardless of status (caller is responsible for filtering)" do
    # tag_as_pending blindly marks everything passed to it.
    # The caller (fetch_and_store_transactions) is responsible for only passing PDNG transactions.
    any_tx = {
      entry_reference: "any_ref",
      transaction_id: "any_txn",
      booking_date: Date.current.to_s,
      transaction_amount: { amount: "20.00", currency: "EUR" },
      credit_debit_indicator: "DBIT",
      status: "BOOK"
    }

    result = @importer.send(:tag_as_pending, [ any_tx ])

    assert_equal true, result.first[:_pending]
  end

  # --- identification_hashes matching ---

  test "find_enable_banking_account_by_hash uses identification_hashes for matching" do
    # Account already exists with uid = identification_hash
    @enable_banking_account.update!(identification_hashes: [ "hash_abc123", "hash_old_xyz" ])

    # Lookup by a secondary hash that is in identification_hashes
    found = @importer.send(:find_enable_banking_account_by_hash, "hash_old_xyz")

    assert_equal @enable_banking_account.id, found.id
  end
end
