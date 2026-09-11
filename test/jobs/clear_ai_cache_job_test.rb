require "test_helper"

class ClearAiCacheJobTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @transaction = transactions(:one)
    @entry = entries(:transaction)
  end

  test "logs start and completion with the number of AI cache entries removed" do
    create_ai_enrichment(@transaction, "category_id")
    create_ai_enrichment(@transaction, "merchant_id")
    create_ai_enrichment(@entry, "name")
    DataEnrichment.create!(enrichable: @transaction, attribute_name: "notes", source: "rule", value: "keep me")

    ClearAiCacheJob.perform_now(@family)

    assert_equal 0, DataEnrichment.where(enrichable: @transaction, source: "ai").count
    assert_equal 1, DataEnrichment.where(enrichable: @transaction, source: "rule").count

    assert_equal @family, start_entry.family

    assert_match "removed 3 AI cache entries", completion_entry.message
    assert_equal 3, completion_entry.metadata["entries_removed"]
    assert_equal({ "transactions" => 2, "entries" => 1 }, completion_entry.metadata["removed_by_scope"])
    assert_equal @family, completion_entry.family
  end

  test "logs an error and still reports the surviving scope when one scope fails" do
    create_ai_enrichment(@entry, "name")
    Transaction.stubs(:clear_ai_cache).raises(ActiveRecord::StatementInvalid, "boom")

    ClearAiCacheJob.perform_now(@family)

    errors = log_entries("error")
    assert_equal 1, errors.size
    assert_match "AI cache reset failed while clearing transactions", errors.first.message
    assert_equal "transactions", errors.first.metadata["scope"]

    assert_match "completed with errors", completion_entry.message
    assert_match "removed 1 AI cache entry", completion_entry.message
    assert_equal({ "transactions" => 0, "entries" => 1 }, completion_entry.metadata["removed_by_scope"])
  end

  test "warns about records it cannot clear instead of losing the whole run" do
    transaction_count = Transaction.family_scope(@family).count
    assert transaction_count.positive?, "fixture setup should leave the family some transactions"

    Transaction.any_instance.stubs(:clear_ai_cache).raises(StandardError, "record is wedged")

    ClearAiCacheJob.perform_now(@family)

    warnings = log_entries("warn")
    assert_equal [ transaction_count, ClearAiCacheJob::MAX_LOGGED_RECORD_ERRORS ].min, warnings.size
    assert_match "AI cache reset could not clear transaction", warnings.first.message

    assert_match "Skipped #{transaction_count} record", completion_entry.message
    assert_equal({ "transactions" => transaction_count }, completion_entry.metadata["skipped_records"])
    assert_equal 0, completion_entry.metadata["entries_removed"]
  end

  test "warns instead of failing silently when no family is given" do
    ClearAiCacheJob.perform_now(nil)

    warnings = log_entries("warn")
    assert_equal 1, warnings.size
    assert_equal "AI cache reset skipped: job received no family", warnings.first.message
    assert_empty log_entries("info")
  end

  private
    def create_ai_enrichment(record, attribute_name)
      DataEnrichment.create!(enrichable: record, attribute_name: attribute_name, source: "ai", value: "ai value")
    end

    def log_entries(level)
      DebugLogEntry.where(category: ClearAiCacheJob::DEBUG_CATEGORY, level: level).order(:created_at).to_a
    end

    def start_entry
      log_entries("info").find { |entry| entry.message.start_with?("AI cache reset started") }
    end

    def completion_entry
      log_entries("info").find { |entry| entry.message.start_with?("AI cache reset completed") }
    end
end
