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
  end

  test "does not run a shadow by default" do
    txn = create_transaction(account: @account, name: "Coffee shop").transaction
    category = @family.categories.create!(name: "Coffee")
    requests = answer_both(llm: { txn.id => category.name }, jev: {})

    assert_equal 0.0, @family.effective_categorization_shadow_rate
    assert_no_enqueued_jobs(only: Ai::ShadowJob) { categorize([ txn.id ]) }
    assert_equal [ :categorize ], requests.map(&:feature)
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

  test "the shadow gets the transactions the primary left unanswered" do
    @family.update!(categorization_shadow_rate: 1.0)
    category = @family.categories.create!(name: "Coffee")
    answered, missed = 2.times.map { create_transaction(account: @account, name: "Coffee #{_1}").transaction }
    answer_both(llm: { answered.id => category.name }, jev: [ answered, missed ].to_h { [ _1.id, [ category.name, 0.9 ] ] })

    perform_enqueued_jobs { categorize([ answered.id, missed.id ]) }

    shadow_only = Ai::Comparison.find_by!(subject_id: missed.id)
    assert_nil shadow_only.primary_value
    assert_equal category.id, shadow_only.shadow_value
    assert_nil missed.reload.category
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

  test "counts a shared abstention as agreement" do
    @family.update!(categorization_shadow_rate: 1.0)
    txn = create_transaction(account: @account, name: "ACH DEBIT 4471920").transaction
    @family.categories.create!(name: "Coffee")
    answer_both(llm: { txn.id => nil }, jev: { txn.id => [ Ai::Judgements::CategorizeTransaction::UNCATEGORIZED, 0.94 ] })

    perform_enqueued_jobs { categorize([ txn.id ]) }

    assert Ai::Comparison.sole.agreed
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

  test "no shadow route, no job" do
    use_ai_routes(shadow_categorize: [])
    @family.update!(categorization_shadow_rate: 1.0)
    txn = create_transaction(account: @account, name: "Coffee shop").transaction
    category = @family.categories.create!(name: "Coffee")
    answer_both(llm: { txn.id => category.name }, jev: {})

    assert_no_enqueued_jobs(only: Ai::ShadowJob) { categorize([ txn.id ]) }
    assert_equal category, txn.reload.category
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

  test "a deadlock is discarded, not retried" do
    Family.stubs(:find_by).raises(ActiveRecord::Deadlocked)

    assert_nothing_raised do
      Ai::ShadowJob.perform_now("Ai::Generations::CategorizeTransactions", @family.id, {}, {})
    end
    assert_equal 0, Ai::Comparison.count
  end

  test "two shadow runs get different correlation ids" do
    @family.update!(categorization_shadow_rate: 1.0)
    txns = Array.new(2) { create_transaction(account: @account, name: "Coffee shop #{_1}").transaction }
    category = @family.categories.create!(name: "Coffee")
    answer_both(llm: txns.to_h { [ _1.id, category.name ] }, jev: txns.to_h { [ _1.id, [ category.name, 0.9 ] ] })
    events = []
    subscription = ActiveSupport::Notifications.subscribe(/.ai\z/) { events << _1.payload }

    perform_enqueued_jobs { categorize([ txns.first.id ]) }
    perform_enqueued_jobs { categorize([ txns.second.id ]) }

    ids = events.select { _1[:feature] == "shadow_categorize" }.map { _1[:correlation_id] }.uniq
    assert_equal 2, ids.size
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

  test "runs on the background lane's queue" do
    assert_equal Ai::Routes.queue_for(:shadow_categorize),
                 Ai::ShadowJob.new("Ai::Generations::CategorizeTransactions", @family.id, {}, {}).queue_name
  end

  test "refuses a class that declares no shadow" do
    assert_raises(ArgumentError) { Ai::ShadowJob.perform_now("Ai::Generations::DetectMerchants", @family.id, {}, {}) }
  end

  private
    def categorize(transaction_ids)
      Ai::GenerationJob.perform_now(:categorize, { ids: transaction_ids, family_id: @family.id })
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
