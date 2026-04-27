require "test_helper"

class GocardlessItem::ImporterDedupTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @gocardless_item = GocardlessItem.create!(
      family:         @family,
      name:           "Monzo",
      institution_id: "MONZO_MONZGB2L",
      status:         :good,
      requisition_id: "req_dedup_test"
    )

    mock_client = mock
    @importer = GocardlessItem::Importer.new(@gocardless_item, client: mock_client)
  end

  # ---------------------------------------------------------------------------
  # deduplicate_api_response
  # ---------------------------------------------------------------------------

  test "removes exact duplicate when API returns the same transaction twice" do
    tx = base_tx("int_aaa", "2026-04-19", "-12.50", "Freshto Ideal")

    result = @importer.send(:deduplicate_api_response, [ tx, tx.dup ])
    assert_equal 1, result.count
    assert_equal "int_aaa", result.first["internalTransactionId"]
  end

  test "keeps transactions with different amounts" do
    transactions = [
      base_tx("int_001", "2026-04-19", "-12.50", "Freshto Ideal"),
      base_tx("int_002", "2026-04-19", "-25.00", "Freshto Ideal")
    ]

    result = @importer.send(:deduplicate_api_response, transactions)
    assert_equal 2, result.count
  end

  test "keeps transactions with different dates" do
    transactions = [
      base_tx("int_001", "2026-04-18", "-12.50", "Spar"),
      base_tx("int_002", "2026-04-19", "-12.50", "Spar")
    ]

    result = @importer.send(:deduplicate_api_response, transactions)
    assert_equal 2, result.count
  end

  # ---------------------------------------------------------------------------
  # Key insight from sandbox: transactionId collides; internalTransactionId is unique
  # Two booked transactions share "2026042301773517-1" but have different internalTransactionIds
  # ---------------------------------------------------------------------------

  test "preserves two transactions that share a transactionId but have different internalTransactionIds" do
    transactions = [
      base_tx("B20260419T142012645abc", "2026-04-19", "-12.50", "Freshto Ideal",
              transaction_id: "2026042301773517-1"),
      base_tx("B20260423T083927645xyz", "2026-04-23", "2500.00", "Liam Brown",
              transaction_id: "2026042301773517-1")
    ]

    result = @importer.send(:deduplicate_api_response, transactions)
    assert_equal 2, result.count
  end

  test "keeps two transactions with same amount and merchant but different internalTransactionIds" do
    # Different internalTransactionId = genuinely different transactions (e.g. two coffee purchases
    # at the same shop on the same day for the same amount). Both must be preserved.
    transactions = [
      base_tx("int_x", "2026-04-19", "-12.50", "Freshto Ideal"),
      base_tx("int_y", "2026-04-19", "-12.50", "Freshto Ideal")
    ]

    result = @importer.send(:deduplicate_api_response, transactions)
    assert_equal 2, result.count
  end

  test "returns empty array for empty input" do
    assert_equal [], @importer.send(:deduplicate_api_response, [])
  end

  # ---------------------------------------------------------------------------
  # build_content_key differentiates on remittance
  # ---------------------------------------------------------------------------

  test "keeps rent payments with different remittance text as distinct transactions" do
    transactions = [
      base_tx("int_001", "2026-04-01", "-800.00", "Landlord",
              remittance: "Rent March"),
      base_tx("int_002", "2026-04-01", "-800.00", "Landlord",
              remittance: "Rent April")
    ]

    result = @importer.send(:deduplicate_api_response, transactions)
    assert_equal 2, result.count
  end

  # ---------------------------------------------------------------------------
  # Incremental dedup — existing_ids and booked_ids prefer internalTransactionId
  # These exercise the private helpers directly (same approach as EnableBanking dedup tests)
  # ---------------------------------------------------------------------------

  test "new_booked rejects transaction already in existing payload by internalTransactionId" do
    existing_payload = [
      base_tx("B20260419T142012645abc", "2026-04-19", "-12.50", "Freshto Ideal")
    ]

    incoming_booked = [
      base_tx("B20260419T142012645abc", "2026-04-19", "-12.50", "Freshto Ideal")
    ]

    existing_ids = existing_payload.map { |t|
      (t["internalTransactionId"] || t[:internalTransactionId]).presence ||
        (t["transactionId"] || t[:transactionId]).presence
    }.compact.to_set

    new_booked = incoming_booked.reject do |txn|
      id = txn["internalTransactionId"].presence || txn["transactionId"].presence
      id.present? && existing_ids.include?(id)
    end

    assert_empty new_booked, "already-stored transaction should not be re-imported"
  end

  test "new_booked keeps a transaction whose internalTransactionId is not in existing payload" do
    existing_payload = [
      base_tx("B20260418T100000645old", "2026-04-18", "-8.00", "Spar")
    ]

    incoming_booked = [
      base_tx("B20260419T142012645abc", "2026-04-19", "-12.50", "Freshto Ideal")
    ]

    existing_ids = existing_payload.map { |t|
      (t["internalTransactionId"] || t[:internalTransactionId]).presence ||
        (t["transactionId"] || t[:transactionId]).presence
    }.compact.to_set

    new_booked = incoming_booked.reject do |txn|
      id = txn["internalTransactionId"].presence || txn["transactionId"].presence
      id.present? && existing_ids.include?(id)
    end

    assert_equal 1, new_booked.count
    assert_equal "B20260419T142012645abc", new_booked.first["internalTransactionId"]
  end

  test "stale pending is removed when booked version arrives with matching internalTransactionId" do
    pending_tx = base_tx("P20260424T090000645pnd", nil, "-5.00", "Costa Coffee")
                   .merge("_pending" => true, "valueDate" => "2026-04-24")

    existing_payload = [ pending_tx ]

    booked_tx = base_tx("P20260424T090000645pnd", "2026-04-25", "-5.00", "Costa Coffee")

    booked_ids = [ booked_tx ].map { |t|
      t["internalTransactionId"].presence || t["transactionId"].presence
    }.compact.to_set

    existing_payload.reject! do |t|
      t["_pending"] && (booked_ids.include?(t["internalTransactionId"].to_s.presence) ||
                        booked_ids.include?(t["transactionId"].to_s.presence))
    end

    assert_empty existing_payload, "pending entry should be cleared once its booked version arrives"
  end

  private

    def base_tx(internal_id, booking_date, amount, counterparty, transaction_id: nil, remittance: nil)
      tx = {
        "internalTransactionId" => internal_id,
        "bookingDate"           => booking_date,
        "valueDate"             => booking_date || Date.current.to_s,
        "transactionAmount"     => { "amount" => amount, "currency" => "GBP" },
        "remittanceInformationUnstructured" => remittance
      }
      tx["transactionId"] = transaction_id if transaction_id
      if amount.to_f.negative?
        tx["creditorName"] = counterparty
      else
        tx["debtorName"] = counterparty
      end
      tx
    end
end
