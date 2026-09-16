# Pure value tests: runnable without Rails, a database or network.
require "minitest/autorun"
require "json"
require_relative "../../../app/models/provider"
require_relative "../../../app/models/provider/account_data"
require_relative "../../../app/models/provider/account_data/page"
require_relative "../../../app/models/ingestion/codec"

class Ingestion::CodecTest < Minitest::Test
  def test_json_round_trip_preserves_exact_decimals_dates_and_metadata_key_types
    original = page
    result = Ingestion::Codec.load(wire_payload(original))

    assert_equal original.records.map(&:attributes), result.records.map(&:attributes)
    assert_equal BigDecimal("-12345678901234567890.12345678901234567890"), result.records.first[:amount]
    assert_instance_of BigDecimal, result.records.first[:amount]
    assert_instance_of Date, result.records.first[:date]
    assert_equal original.coverage, result.coverage
    assert_equal original.warnings, result.warnings
    assert_equal "symbol-key", result.records.first[:metadata][:same]
    assert_equal "string-key", result.records.first[:metadata]["same"]
    assert_equal 9007199254740993, result.records.first[:metadata]["large_integer"]
    assert result.frozen?
    assert_raises(FrozenError) { result.records.first[:metadata]["same"].replace("changed") }
  end

  def test_partial_snapshots_retain_continuation_coverage_and_removed_ids
    original = page(complete: false, mode: "snapshot", next_cursor: "opaque-page",
      removed_ids: [ "removed-id" ], checkpoint_cursor: "pending-checkpoint")
    result = Ingestion::Codec.load(wire_payload(original))

    refute result.complete?
    assert_equal "snapshot", result.mode
    assert_equal "opaque-page", result.next_cursor
    assert_equal "pending-checkpoint", result.checkpoint_cursor
    assert_equal [ "removed-id" ], result.removed_ids
    assert_equal original.coverage, result.coverage
  end

  def test_complete_empty_snapshots_and_delta_checkpoints_remain_distinct
    empty = Provider::AccountData::Page.new(records: [], complete: true, mode: "snapshot")
    delta = page(checkpoint_cursor: "next-sync")

    empty_result = Ingestion::Codec.load(wire_payload(empty))
    assert_empty empty_result.records
    assert empty_result.complete?
    assert_equal "snapshot", empty_result.mode
    assert_nil empty_result.checkpoint_cursor
    delta_result = Ingestion::Codec.load(wire_payload(delta))
    assert_equal "delta", delta_result.mode
    assert_equal "next-sync", delta_result.checkpoint_cursor
    assert_nil delta_result.next_cursor
  end

  def test_progress_cursor_is_distinct_from_authoritative_checkpoint
    original = page(complete: false, next_cursor: "same-run", progress_cursor: "later-run")
    result = Ingestion::Codec.load(wire_payload(original))
    assert_equal "same-run", result.next_cursor
    assert_equal "later-run", result.progress_cursor
    assert_nil result.checkpoint_cursor
    assert_raises(ArgumentError) { page(complete: true, progress_cursor: "unfinished") }

    old_payload = wire_payload
    old_payload.delete("progress_cursor")
    assert_nil Ingestion::Codec.load(old_payload).progress_cursor
  end

  def test_source_metadata_cannot_impersonate_serialized_type_tags
    metadata = { "type" => "decimal", "value" => "not a number", "tag" => [ "date", "not a date" ] }
    original = page(records: [ transaction(metadata: metadata) ])

    result = Ingestion::Codec.load(wire_payload(original))

    assert_equal metadata, result.records.first[:metadata]
  end

  def test_rejects_unsupported_versions_and_malformed_page_envelopes
    [ nil, [], "private-payload", {} ].each do |payload|
      assert_raises(ArgumentError) { Ingestion::Codec.load(payload) }
    end
    [ 0, 2, 1.0, "1" ].each do |version|
      assert_raises(ArgumentError) { Ingestion::Codec.load(wire_payload.merge("version" => version)) }
    end
    [ "records", "coverage", "next_cursor" ].each do |key|
      payload = wire_payload
      payload.delete(key)
      assert_raises(ArgumentError) { Ingestion::Codec.load(payload) }
    end
    assert_raises(ArgumentError) { Ingestion::Codec.load(wire_payload.merge("unexpected" => "value")) }
    assert_raises(ArgumentError) { Ingestion::Codec.load(wire_payload.merge("records" => {})) }
    assert_raises(ArgumentError) { Ingestion::Codec.load(wire_payload.merge("complete" => "false")) }
    assert_raises(ArgumentError) { Ingestion::Codec.load(wire_payload.merge("next_cursor" => "invalid-on-complete-page")) }
  end

  def test_rejects_malformed_record_envelopes
    [ nil, [], {}, { "kind" => "transaction", "attributes" => [], "unexpected" => true } ].each do |record|
      payload = wire_payload.merge("records" => [ record ])
      assert_raises(ArgumentError) { Ingestion::Codec.load(payload) }
    end
  end

  def test_rejects_malformed_tags_untyped_containers_and_nonfinite_metadata
    malformed_values = [
      nil, "scalar", [], [ "scalar" ], [ "scalar", 1, "extra" ],
      [ "unknown", "value" ], [ "scalar", [] ], [ "scalar", {} ],
      [ "scalar", Float::INFINITY ], [ "scalar", Float::NAN ],
      [ "decimal", 12 ], [ "decimal", "NaN" ], [ "decimal", "Infinity" ],
      [ "decimal", "private-invalid-number" ], [ "date", "2026-02-30" ],
      [ "date", "2026-09-14T12:00:00Z" ], [ "symbol", 123 ],
      [ "array", {} ], [ "hash", {} ], [ "hash", [ [ [ "scalar", "key" ] ] ] ]
    ]
    malformed_values.each do |value|
      payload = wire_payload.merge("warnings" => [ "array", [ value ] ])
      error = assert_raises(ArgumentError) { Ingestion::Codec.load(payload) }
      assert_equal "Invalid ingestion payload", error.message
      refute_includes error.message, "private-invalid-number"
      assert_nil error.cause
    end
  end

  def test_duplicate_decoded_hash_keys_cannot_silently_overwrite_metadata
    pair = [ [ "scalar", "from" ], [ "scalar", "2026-09-01" ] ]
    payload = wire_payload.merge("coverage" => [ "hash", [ pair, pair ] ])

    assert_raises(ArgumentError) { Ingestion::Codec.load(payload) }
  end

  def test_canonical_record_validation_still_rejects_float_money_after_decoding
    payload = wire_payload
    pairs = payload.fetch("records").first.fetch("attributes").last
    amount_pair = pairs.find { |key, _| key == [ "symbol", "amount" ] }
    amount_pair[1] = [ "scalar", 1.25 ]

    assert_raises(ArgumentError) { Ingestion::Codec.load(payload) }
  end

  def test_dump_requires_a_canonical_page_and_never_truncates_timestamp_metadata
    assert_raises(ArgumentError) { Ingestion::Codec.dump({}) }
    value = transaction(metadata: { "reported_at" => DateTime.iso8601("2026-09-14T12:30:00+10:00") })

    assert_raises(ArgumentError) { Ingestion::Codec.dump(page(records: [ value ])) }
  end

  def test_original_evidence_round_trips_exactly_without_exposing_it_in_inspection
    evidence = { "response" => { items: [ { "private_account" => "private-account-number", amount: BigDecimal("123.456789012345678901") } ] } }
    original = page(evidence: evidence)
    evidence["response"][:items].first["private_account"].replace("changed")
    result = Ingestion::Codec.load(wire_payload(original))

    assert_equal "private-account-number", result.evidence["response"][:items].first["private_account"]
    assert_equal BigDecimal("123.456789012345678901"), result.evidence["response"][:items].first[:amount]
    assert_equal original.evidence, result.evidence
    assert_raises(FrozenError) { result.evidence["response"][:items] << "changed" }
    refute_includes result.inspect, "private-account-number"
  end

  def test_version_one_batches_captured_before_evidence_was_added_remain_replayable
    payload = wire_payload
    payload.delete("evidence")
    result = Ingestion::Codec.load(payload)

    assert_equal page.records.first.attributes, result.records.first.attributes
    assert_empty result.evidence
  end

  def test_evidence_requires_an_object_and_finite_numbers
    [ nil, [], "private-source-value" ].each do |evidence|
      assert_raises(ArgumentError) { page(evidence: evidence) }
    end
    [ Float::NAN, Float::INFINITY, BigDecimal("NaN"), BigDecimal("Infinity") ].each do |amount|
      assert_raises(ArgumentError) { page(evidence: { "amount" => amount }) }
    end
    [ Time.now, Date.today, transaction ].each do |unsupported|
      assert_raises(ArgumentError) { page(evidence: { "value" => unsupported }) }
    end
    assert_raises(ArgumentError) { Ingestion::Codec.load(wire_payload.merge("evidence" => [ "array", [] ])) }
  end

  def test_evidence_cannot_forge_codec_tags_or_overwrite_duplicate_keys
    source = { "type" => "decimal", "value" => "private-not-decimal", "nested" => [ "decimal", "NaN" ] }
    result = Ingestion::Codec.load(wire_payload(page(evidence: source)))
    assert_equal source, result.evidence
    pair = [ [ "scalar", "key" ], [ "scalar", "value" ] ]
    assert_raises(ArgumentError) { Ingestion::Codec.load(wire_payload.merge("evidence" => [ "hash", [ pair, pair ] ])) }
  end

  private
    def transaction(**overrides)
      Ingestion::Record.transaction(**{
        external_id: "legacy-id", name: "Deposit", currency: "AUD", pending: false,
        amount: BigDecimal("-12345678901234567890.12345678901234567890"), date: Date.new(2026, 9, 14),
        metadata: { same: "symbol-key", "same" => "string-key", "large_integer" => 9007199254740993,
          "fx_amount" => BigDecimal("0.000000000000000001"), "reported_on" => Date.new(2026, 9, 13) }
      }.merge(overrides))
    end

    def page(**overrides)
      Provider::AccountData::Page.new(**{
        records: [ transaction ], complete: true, coverage: { from: Date.new(2026, 9, 1), "resource" => "transactions" },
        warnings: [ { "code" => "partial_metadata", "ratio" => 0.5 } ]
      }.merge(overrides))
    end

    def wire_payload(value = page)
      JSON.parse(JSON.generate(Ingestion::Codec.dump(value)))
    end
end
