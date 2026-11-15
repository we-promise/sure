module FinancekitTestHelper
  def financekit_setup(user: users(:family_admin))
    travel_to Time.utc(2026, 9, 10, 12)
    @user = user
    @family = @user.family
    @source_id = "11111111-1111-4111-8111-111111111111"
    @balance_id = "22222222-2222-4222-8222-222222222222"
    @transaction_id = "33333333-3333-4333-8333-333333333333"
    @enrollment = {
      "enrollment_id" => SecureRandom.uuid,
      "protocol_version" => Financekit::VERSION,
      "consent" => {
        "version" => 1,
        "granted_at" => Time.current.iso8601,
        "selected_source_account_ids" => [ @source_id ],
        "upload_authorized" => true,
        "family_visibility_acknowledged" => true,
        "remote_processing_acknowledged" => true
      }
    }
    @item = Financekit::Enrollment.create!(@user, @enrollment).item
    @mapping_input = {
      "expected_version" => 0,
      "action" => "create",
      "name" => "Test Wallet",
      "institution_name" => "Apple Wallet",
      "currency" => "USD",
      "accountable_type" => "Depository",
      "subtype" => "checking",
      "ledger_timezone" => "America/Los_Angeles",
      "booked_balance" => money("125.00", "credit"),
      "observed_at" => Time.current.iso8601
    }
    @source = FinancekitAccount.map!(@item, @source_id, @mapping_input)
    @credential = @item.activate!
  end

  def money(amount = "12.34", direction = "debit", currency = "USD")
    { "amount" => amount, "currency" => currency, "direction" => direction }
  end

  def financekit_payload(sequence: 1, predecessor_digest: nil, events: financekit_events,
                         item: @item, captured_at: Time.current.iso8601)
    payload = {
      "protocol_version" => Financekit::VERSION,
      "connection_id" => item.id,
      "publisher_id" => item.publisher_id,
      "generation" => item.generation,
      "stream_id" => item.stream_id,
      "batch_id" => SecureRandom.uuid,
      "sequence" => sequence,
      "capture_id" => SecureRandom.uuid,
      "chunk_index" => 0,
      "chunk_count" => 1,
      "capture_mode" => "delta",
      "snapshot_complete" => false,
      "captured_at" => captured_at,
      "selected_source_account_ids" => item.consented_source_ids,
      "events" => events
    }
    payload["predecessor_digest"] = predecessor_digest if predecessor_digest
    payload
  end

  def financekit_events
    now = Time.current.iso8601
    [
      {
        "kind" => "account_upsert",
        "account" => {
          "source_id" => @source_id,
          "lineage_id" => @source.financekit_account_lineage_id,
          "mapping_version" => @source.mapping_version,
          "display_name" => "Test Wallet",
          "institution_name" => "Apple Wallet",
          "currency" => "USD",
          "kind" => "asset"
        }
      },
      {
        "kind" => "balance_upsert",
        "balance" => {
          "source_id" => @balance_id,
          "source_account_id" => @source_id,
          "lineage_id" => @source.financekit_account_lineage_id,
          "mapping_version" => @source.mapping_version,
          "kind" => "booked",
          "observed_at" => now,
          "money" => money("112.66", "credit")
        }
      },
      {
        "kind" => "transaction_upsert",
        "transaction" => {
          "source_id" => @transaction_id,
          "source_account_id" => @source_id,
          "lineage_id" => @source.financekit_account_lineage_id,
          "mapping_version" => @source.mapping_version,
          "amount" => money,
          "transaction_description" => "Synthetic shop",
          "original_transaction_description" => "SYNTHETIC SHOP",
          "transaction_type" => "purchase",
          "status" => "booked",
          "transacted_at" => "2026-09-01T06:00:00Z",
          "posted_at" => "2026-09-01T07:00:00Z",
          "merchant_name" => "Synthetic shop"
        }
      }
    ]
  end

  def accept_batch(payload = financekit_payload, item: @item)
    raw = JSON.generate(payload)
    batch = FinancekitBatch.accept!(item, raw, claimed_digest: Digest::SHA256.hexdigest(raw),
      idempotency_key: payload.fetch("batch_id"))
    [ batch, raw ]
  end

  def accept_and_apply(payload = financekit_payload, item: @item)
    batch, = accept_batch(payload, item: item)
    applied = Financekit::Processor.new(item).apply_next!
    assert applied.present?
    # apply_next! no longer fans out on its own; the job batches a whole drain.
    Financekit::Downstream.new(item, FinancekitBatch.where(id: applied.map(&:id))).perform!
    batch.reload
  end
end
