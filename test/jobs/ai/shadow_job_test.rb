require "test_helper"

# Shadow runs: a categorize batch that the family's rate samples enqueues Ai::ShadowJob, which
# runs the same generation on shadow_categorize with the input actually sent. Its answer reaches
# only Ai::Comparison, never the transaction.
class Ai::ShadowJobTest < ActiveJob::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:dylan_family)
    @account = @family.accounts.create!(name: "Shadow test", balance: 100, currency: "USD", accountable: Depository.new)
    use_ai_routes   # categorize on openai/gpt-4.1-mini, shadow_categorize on jev/jev-latest
    @shadow_rate = ENV.delete("CATEGORIZATION_SHADOW_RATE")   # the host's would override each test's rate
  end

  teardown do
    ENV["CATEGORIZATION_SHADOW_RATE"] = @shadow_rate if @shadow_rate
  end

  test "records a disagreement without applying the shadow answer" do
    @family.update!(categorization_shadow_rate: 1.0)
    txn = create_transaction(account: @account, name: "Blue Bottle Coffee").transaction
    applied = @family.categories.create!(name: "Coffee")
    shadowed = @family.categories.create!(name: "Groceries")
    requests = answer_both(llm: { txn.id => applied.name }, jev: { txn.id => [ shadowed.name, 0.88 ] })

    assert_difference "Ai::Comparison.count", 1 do
      perform_enqueued_jobs { categorize([ txn.id ]) }
    end

    assert_equal applied, txn.reload.category
    assert_equal %i[categorize shadow_categorize], requests.map(&:feature)

    comparison = Ai::Comparison.sole
    assert_equal "categorize", comparison.feature
    assert_equal txn, comparison.subject
    assert_not comparison.agreed
    assert_equal [ "openai", "jev" ], [ comparison.primary_endpoint, comparison.shadow_endpoint ]
    assert_equal "gpt-4.1-mini", comparison.primary_route["model"]
    assert_equal [ applied.id, shadowed.id ], [ comparison.primary_value, comparison.shadow_value ]
    assert_nil comparison.primary_confidence
    assert_in_delta 0.88, comparison.shadow_confidence, 0.001
  end

  test "the shadow gets the batch the primary was sent, not the rest of the job's ids" do
    @family.update!(categorization_shadow_rate: 1.0)
    category = @family.categories.create!(name: "Coffee")
    txns = Array.new(3) { create_transaction(account: @account, name: "Coffee #{_1}").transaction }
    requests = answer_both(llm: txns.to_h { [ _1.id, category.name ] }, jev: txns.to_h { [ _1.id, [ category.name, 0.9 ] ] })

    use_ai_model_settings(batch_size: 2)

    perform_enqueued_jobs(only: Ai::ShadowJob) { categorize(txns.map(&:id)) }

    shadow = requests.select { _1.feature == :shadow_categorize }.sole
    assert_equal 2, shadow.states.size
    assert_equal 2, Ai::Comparison.where(agreed: true).count
  end

  test "does not score a missing shadow answer as agreement" do
    @family.update!(categorization_shadow_rate: 1.0)
    txn = create_transaction(account: @account, name: "ACH DEBIT 4471920").transaction
    @family.categories.create!(name: "Coffee")
    answer_both(llm: { txn.id => nil }, jev: {})

    perform_enqueued_jobs { categorize([ txn.id ]) }

    comparison = Ai::Comparison.sole
    assert_not comparison.agreed
    assert_nil comparison.shadow_value
  end

  test "a failing shadow model breaks nothing and records nothing" do
    @family.update!(categorization_shadow_rate: 1.0)
    txn = create_transaction(account: @account, name: "Coffee shop").transaction
    category = @family.categories.create!(name: "Coffee")
    stub_ai do |request|
      raise Ai::Error::Upstream, "upstream down" if request.is_a?(Ai::Transport::Base::JudgeRequest)

      { categorizations: [ { transaction_id: txn.id, category_name: category.name } ] }
    end

    assert_nothing_raised do
      perform_enqueued_jobs { categorize([ txn.id ]) }
    end

    assert_equal category, txn.reload.category
    assert_equal 0, Ai::Comparison.count
  end

  test "the shadow's usage rows are its own, tagged shadow" do
    @family.update!(categorization_shadow_rate: 1.0)
    txn = create_transaction(account: @account, name: "Coffee shop").transaction
    category = @family.categories.create!(name: "Coffee")
    events = []
    subscription = ActiveSupport::Notifications.subscribe("judge.ai") { events << _1.payload }
    answer_both(llm: { txn.id => category.name }, jev: { txn.id => [ category.name, 0.9 ] })

    perform_enqueued_jobs { categorize([ txn.id ]) }

    assert_equal [ [ "shadow_categorize", true ] ], events.map { [ _1[:feature], _1[:shadow] ] }
  ensure
    ActiveSupport::Notifications.unsubscribe(subscription)
  end

  test "a shadow run never enqueues another shadow" do
    @family.update!(categorization_shadow_rate: 1.0)
    txn = create_transaction(account: @account, name: "Coffee shop").transaction
    category = @family.categories.create!(name: "Coffee")
    answer_both(llm: { txn.id => category.name }, jev: { txn.id => [ category.name, 0.9 ] })

    enqueued = []
    Ai::ShadowJob.stub(:perform_later, ->(*args) { enqueued << args }) do
      perform_enqueued_jobs { categorize([ txn.id ]) }
    end

    assert_equal 1, enqueued.size, "the primary enqueues its shadow; the shadow enqueues nothing of its own"
  end

  test "a transaction edited while the shadow waits isn't compared; the others still are" do
    @family.update!(categorization_shadow_rate: 1.0)
    edited, kept = [ "Coffee shop", "Corner cafe" ].map { create_transaction(account: @account, name: _1).transaction }
    category = @family.categories.create!(name: "Coffee")
    answer_both(llm: [ edited, kept ].to_h { [ _1.id, category.name ] }, jev: [ edited, kept ].to_h { [ _1.id, [ category.name, 0.9 ] ] })

    categorize([ edited.id, kept.id ])
    edited.entry.update!(name: "Grocery store")
    perform_enqueued_jobs(only: Ai::ShadowJob)

    assert_equal [ kept.id ], Ai::Comparison.pluck(:subject_id)
  end

  test "each comparison records the route that answered its own item" do
    @family.update!(categorization_shadow_rate: 1.0)
    use_ai_routes(categorize: %w[gpu/qwen3-8b openai/gpt-4.1-mini])
    category = @family.categories.create!(name: "Coffee")
    first, second = 2.times.map { create_transaction(account: @account, name: "Coffee #{_1}").transaction }
    gpu_answers = 0
    stub_ai do |request|
      next request.states.keys.index_with { { category: [ category.name, 0.9 ] } } if request.is_a?(Ai::Transport::Base::JudgeRequest)

      ids = [ first.id, second.id ].select { request.input.include?(_1) }
      if request.model.endpoint.name == "gpu"
        raise Ai::Error::ContextTooLong, "too long" if ids.size > 1
        raise Ai::Error::InvalidOutput, "garbage" if (gpu_answers += 1) > 1   # whichever item comes second
      end
      { categorizations: ids.map { { transaction_id: _1, category_name: category.name } } }
    end

    perform_enqueued_jobs { categorize([ first.id, second.id ]) }

    routes = [ first, second ].map { Ai::Comparison.find_by!(subject_id: _1.id).primary_endpoint }
    assert_equal %w[gpu openai], routes.sort
  end

  test "a batch retried after a deadlock while applying is shadowed once" do
    @family.update!(categorization_shadow_rate: 1.0)
    txn = create_transaction(account: @account, name: "Coffee shop").transaction
    category = @family.categories.create!(name: "Coffee")
    answer_both(llm: { txn.id => category.name }, jev: { txn.id => [ category.name, 0.9 ] })
    Transaction.any_instance.stubs(:lock_attr!).raises(ActiveRecord::Deadlocked).then.returns(true)

    assert_no_enqueued_jobs(only: Ai::ShadowJob) { categorize([ txn.id ]) }
    perform_enqueued_jobs   # the retry, which applies and enqueues the shadow
    perform_enqueued_jobs   # the shadow

    assert_equal category, txn.reload.category
    assert_equal 1, Ai::Comparison.count
  end

  private
    def categorize(transaction_ids)
      Ai::GenerationJob.perform_now(:categorize, ai_run_args(:categorize, ids: transaction_ids, family: @family))
    end

    # The LLM answers categorize (`llm`: id => name); the shadow's Jev answers shadow_categorize
    # (`jev`: id => [name, confidence]).
    def answer_both(llm:, jev:)
      stub_ai do |request|
        next jev.transform_values { { category: _1 } } if request.is_a?(Ai::Transport::Base::JudgeRequest)

        { categorizations: llm.map { |id, name| { transaction_id: id, category_name: name } } }
      end
    end
end
