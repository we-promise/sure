require "test_helper"

# A generation run is linear (#5077): each Ai::GenerationJob reads one window of the run, so the
# records a job loads and the bytes it carries to the next stay the same however long the run is.
class AiGenerationLinearTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  BATCH = 20

  setup do
    @family = families(:dylan_family)
    @account = @family.accounts.create!(name: "Linear", balance: 0, currency: "USD", accountable: Depository.new)
    @category = @family.categories.create!(name: "Linear category")
    use_ai_routes
    use_ai_model_settings(batch_size: BATCH)
    stub_ai(:categorize) do |request|
      ids = request.schema.dig(:properties, :categorizations, :items, :properties, :transaction_id, :enum)
      { categorizations: ids.map { { transaction_id: _1, category_name: @category.name } } }
    end
  end

  test "per-job records and payload stay flat from 200 to 2,000 transactions" do
    small = run_categorize(200)
    large = run_categorize(2_000)

    assert_equal 200 / BATCH, small[:jobs]
    assert_equal 2_000 / BATCH, large[:jobs]
    assert_operator large[:max_records], :<=, small[:max_records], "a job loads one window's records, not the run's"
    assert_operator large[:max_payload], :<=, small[:max_payload] + 64, "a job carries a cursor, not the rest of the run"
    assert_operator large[:max_payload], :<, 2_000, "the payload stays within one window of ids"
  end

  private
    def run_categorize(count)
      ids = insert_transactions(count)
      Ai::GenerationRun.enqueue(:categorize, family: @family, ids:)
      jobs = 0
      max_records = 0
      max_payload = 0

      until enqueued_jobs.empty?
        job = enqueued_jobs.shift
        max_payload = [ max_payload, job["arguments"].to_json.bytesize ].max
        records = 0
        counter = ->(*, payload) { records += payload[:record_count] }
        ActiveSupport::Notifications.subscribed(counter, "instantiation.active_record") do
          ActiveJob::Base.execute(job.stringify_keys)
        end
        jobs += 1
        max_records = [ max_records, records ].max
      end

      assert_equal count, Transaction.where(id: ids, category_id: @category.id).count, "every transaction is applied"
      assert_equal 0, Ai::GenerationRun.count, "the run's rows are gone at the end"
      { jobs:, max_records:, max_payload: }
    end

    def insert_transactions(count)
      now = Time.current
      transaction_ids = Transaction.insert_all!(Array.new(count) { { created_at: now, updated_at: now } }, returning: :id).rows.flatten
      Entry.insert_all!(transaction_ids.each_with_index.map do |id, i|
        { account_id: @account.id, entryable_type: "Transaction", entryable_id: id, name: "Shop #{i}", amount: 10,
          currency: "USD", date: Date.current, created_at: now, updated_at: now }
      end)
      transaction_ids
    end
end
