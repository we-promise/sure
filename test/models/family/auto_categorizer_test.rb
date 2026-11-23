require "test_helper"

class Family::AutoCategorizerTest < ActiveSupport::TestCase
  include EntriesTestHelper, ProviderTestHelper, ActiveJob::TestHelper

  setup do
    Ai::LegacyEnvConfig.unreachably_warned = nil   # one-shot latch fires per process; reset it so tests see identical counts
    @family = families(:dylan_family)
    @account = @family.accounts.create!(name: "Rule test", balance: 100, currency: "USD", accountable: Depository.new)
    use_ai_routes
    # The host's CATEGORIZATION_CONFIDENCE_THRESHOLD would override each test's family threshold.
    @confidence_threshold = ENV.delete("CATEGORIZATION_CONFIDENCE_THRESHOLD")
  end

  teardown do
    ENV["CATEGORIZATION_CONFIDENCE_THRESHOLD"] = @confidence_threshold if @confidence_threshold
  end

  test "auto-categorizes transactions" do
    txn1 = create_transaction(account: @account, name: "McDonalds").transaction
    txn2 = create_transaction(account: @account, name: "Amazon purchase").transaction
    txn3 = create_transaction(account: @account, name: "Netflix subscription").transaction

    test_category = @family.categories.create!(name: "Test category")

    stub_ai(:categorize, returns: { categorizations: [
      { transaction_id: txn1.id, category_name: test_category.name },
      { transaction_id: txn2.id, category_name: test_category.name },
      { transaction_id: txn3.id, category_name: nil }
    ] })

    assert_difference "DataEnrichment.count", 2 do
      categorize([ txn1.id, txn2.id, txn3.id ])
    end

    assert_equal test_category, txn1.reload.category
    assert_equal test_category, txn2.reload.category
    assert_nil txn3.reload.category

    # After auto-categorization, only successfully categorized transactions are locked
    # txn3 remains enrichable since it didn't get a category (allows retry)
    assert_equal 1, @account.transactions.reload.enrichable(:category_id).count
  end

  test "leaves plain transfer legs uncategorized" do
    transfer_leg = create_transaction(account: @account, name: "To brokerage").transaction
    transfer_leg.update!(kind: "funds_movement")
    @family.categories.create!(name: "Investments")
    stub_ai(:categorize) { flunk "the model shouldn't be asked" }

    categorize([ transfer_leg.id ])

    assert_nil transfer_leg.reload.category
  end

  # A sync or confirmation makes the leg a plain transfer after the
  # categorizer selected it: the AI's category must not land on it.
  test "leaves a leg that became a plain transfer after it was selected uncategorized" do
    leg = create_transaction(account: @account, name: "To brokerage").transaction
    category = @family.categories.create!(name: "Investments")
    categorizer = Family::AutoCategorizer.new(@family, transaction_ids: [ leg.id ])
    categorizer.ai_generation
    Transaction.where(id: leg.id).update_all(kind: "funds_movement")

    assert_equal 0, categorizer.apply_ai(Ai::Result.new(value: { categorizations: [
      { transaction_id: leg.id, category_name: category.name }
    ] }))
    leg.reload
    assert_nil leg.category
    assert_not leg.locked?(:category_id)
  end

  test "a category deleted while the AI answers is skipped, and the rest of the batch still applies" do
    gone = @family.categories.create!(name: "Coffee")
    kept = @family.categories.create!(name: "Groceries")
    coffee, groceries = [ "Blue Bottle", "Safeway" ].map { create_transaction(account: @account, name: _1).transaction }
    categorizer = Family::AutoCategorizer.new(@family, transaction_ids: [ coffee.id, groceries.id ])
    categorizer.ai_generation   # reads the family's categories
    gone.destroy!

    categorizer.apply_ai(Ai::Result.new(value: { categorizations: [
      { transaction_id: coffee.id, category_name: "Coffee" }, { transaction_id: groceries.id, category_name: "Groceries" }
    ] }))

    assert_nil coffee.reload.category
    assert_equal kept, groceries.reload.category
  end

  test "re-applying the same result does not double-apply; the enrichment lock wins" do
    category = @family.categories.create!(name: "Coffee")
    txn = create_transaction(account: @account, name: "Blue Bottle").transaction
    categorizer = Family::AutoCategorizer.new(@family, transaction_ids: [ txn.id ])
    categorizer.ai_generation
    result = Ai::Result.new(value: { categorizations: [ { transaction_id: txn.id, category_name: "Coffee" } ] })

    assert_equal 1, categorizer.apply_ai(result)
    enrichments = DataEnrichment.count

    # A crash between the batch commit and the enqueue of the rest leaves this job
    # to run again with the same ids; the lock is what makes it a no-op.
    assert_equal 0, categorizer.apply_ai(result)
    assert_equal enrichments, DataEnrichment.count
    assert_equal category, txn.reload.category
  end

  test "each batch logs only its own transactions, not every one still left in the run" do
    use_ai_model_settings(batch_size: 2)
    category = @family.categories.create!(name: "Coffee")
    ids = 3.times.map { |i| create_transaction(account: @account, name: "Coffee #{i}").transaction.id }
    stub_ai(:categorize) do |request|
      batch = request.schema.dig(:properties, :categorizations, :items, :properties, :transaction_id, :enum)
      { categorizations: batch.map { { transaction_id: _1, category_name: category.name } } }
    end

    perform_enqueued_jobs { Ai::GenerationJob.perform_later(:categorize, ai_run_args(:categorize, ids: ids, family: @family)) }

    logged = DebugLogEntry.where(message: "AI categorization completed").order(:created_at).map { _1.metadata["requested_transaction_ids"] }
    assert_equal [ 2, 1 ], logged.map(&:size)
    assert_equal ids.sort, logged.flatten.sort
  end

  test "a rule run on Jev counts a withheld answer as handled, not modified" do
    use_ai_routes(categorize: %w[jev/jev-latest])
    @family.update!(categorization_confidence_threshold: 0.7)
    category = @family.categories.create!(name: "Coffee")
    sure, unsure = 2.times.map { |i| create_transaction(account: @account, name: "Coffee #{i}").transaction.id }
    rule_run = RuleRun.create!(rule: rules(:one), execution_type: "manual", status: "pending", pending_jobs_count: 0,
                               transactions_queued: 2, executed_at: Time.current)
    rule_run.await_ai!(2)
    stub_ai(:categorize) { { sure => { category: [ category.name, 0.9 ] }, unsure => { category: [ category.name, 0.3 ] } } }

    Ai::GenerationJob.perform_now(:categorize, ai_run_args(:categorize, ids: [ sure, unsure ], family: @family, rule_run_id: rule_run.id))

    assert_equal [ 0, 1, "success" ], rule_run.reload.slice(:transactions_awaiting_ai, :transactions_modified, :status).values
  end

  test "a failed generation fails the rule run's job and is logged" do
    txn = create_transaction(account: @account, name: "Coffee shop").transaction
    @family.categories.create!(name: "Coffee")
    rule_run = RuleRun.create!(rule: rules(:one), execution_type: "manual", status: "pending", pending_jobs_count: 1,
                               transactions_queued: 1, executed_at: Time.current)
    stub_ai(:categorize, raises: Ai::Error::InvalidOutput.new("no JSON"))

    assert_difference -> { DebugLogEntry.where(message: "AI categorization failed").count }, 1 do
      Ai::GenerationJob.perform_now(:categorize, ai_run_args(:categorize, ids: [ txn.id ], family: @family, rule_run_id: rule_run.id))
    end

    assert_equal "failed", rule_run.reload.status
    assert_includes rule_run.error_message, "no JSON"
  end

  test "no categories fails the rule run's job, logs why, and asks no model" do
    @family.categories.destroy_all
    txn = create_transaction(account: @account, name: "Coffee shop").transaction
    rule_run = RuleRun.create!(rule: rules(:one), execution_type: "manual", status: "pending", pending_jobs_count: 1,
                               transactions_queued: 1, executed_at: Time.current)
    stub_ai(:categorize) { flunk "the model shouldn't be asked" }

    Ai::GenerationJob.perform_now(:categorize, ai_run_args(:categorize, ids: [ txn.id ], family: @family, rule_run_id: rule_run.id))

    assert_equal "failed", rule_run.reload.status
    assert_includes rule_run.error_message, "No categories available"
    log_entry = DebugLogEntry.find_by!(message: "AI categorization failed: no categories available")
    assert_equal "auto_categorization", log_entry.category
    assert_equal "error", log_entry.level
    assert_equal "Family::AutoCategorizer", log_entry.source
    assert_equal @family, log_entry.family
    assert_equal [ txn.id ], log_entry.metadata["requested_transaction_ids"]
  end

  test "sends the family's categories and transactions through the route's prompt" do
    txn = create_transaction(account: @account, name: "Blue Bottle Coffee").transaction
    @family.categories.create!(name: "Coffee")
    requests = stub_ai(:categorize, returns: { categorizations: [] })

    categorize([ txn.id ])

    assert_includes requests.first.instructions, "Your job is to auto-categorize"
    assert_includes requests.first.input, "Blue Bottle Coffee"
    assert_includes requests.first.input, "\"name\":\"Coffee\""
    assert_equal "auto_categorize_personal_finance_transactions", requests.first.schema_name
  end

  test "logs when AI categorization cache handles the batch" do
    txn = create_transaction(account: @account, name: "Coffee shop").transaction
    category = @family.categories.create!(name: "Coffee")
    txn.enrich_attribute(:category_id, category.id, source: "ai")
    txn.lock_attr!(:category_id)
    stub_ai(:categorize) { flunk "the model shouldn't be asked" }

    assert_difference "DebugLogEntry.count", 1 do
      categorize([ txn.id ])
    end

    log_entry = DebugLogEntry.order(:created_at).last
    assert_equal "auto_categorization", log_entry.category
    assert_equal "AI categorization cache used", log_entry.message
    assert_equal "Family::AutoCategorizer", log_entry.source
    assert_equal @family, log_entry.family
    assert_equal [ txn.id ], log_entry.metadata["cached_transaction_ids"]
  end

  test "logs when categorization is blocked by enrichment protection" do
    txn = create_transaction(account: @account, name: "Protected transaction").transaction
    txn.lock_attr!(:category_id)
    stub_ai(:categorize) { flunk "the model shouldn't be asked" }

    assert_difference "DebugLogEntry.count", 1 do
      categorize([ txn.id ])
    end

    log_entry = DebugLogEntry.order(:created_at).last
    assert_equal "auto_categorization", log_entry.category
    assert_equal "AI categorization blocked by enrichment protection", log_entry.message
    assert_equal "Family::AutoCategorizer", log_entry.source
    assert_equal @family, log_entry.family
    assert_equal [ txn.id ], log_entry.metadata["blocked_transaction_ids"]
  end

  test "does not treat a user-overridden AI category as cached" do
    txn = create_transaction(account: @account, name: "Coffee shop").transaction
    ai_category = @family.categories.create!(name: "AI category")
    user_category = @family.categories.create!(name: "User category")
    txn.enrich_attribute(:category_id, ai_category.id, source: "ai")
    txn.lock_attr!(:category_id)
    txn.update!(category_id: user_category.id)
    stub_ai(:categorize) { flunk "the model shouldn't be asked" }

    assert_difference "DebugLogEntry.count", 1 do
      categorize([ txn.id ])
    end

    log_entry = DebugLogEntry.order(:created_at).last
    assert_equal "AI categorization blocked by enrichment protection", log_entry.message
    assert_equal [ txn.id ], log_entry.metadata["blocked_transaction_ids"]
  end

  test "logs AI cache usage alongside LLM categorization" do
    cached_txn = create_transaction(account: @account, name: "Coffee shop").transaction
    llm_txn = create_transaction(account: @account, name: "Bakery").transaction
    category = @family.categories.create!(name: "Coffee")
    cached_txn.enrich_attribute(:category_id, category.id, source: "ai")
    cached_txn.lock_attr!(:category_id)

    stub_ai(:categorize, returns: { categorizations: [
      { transaction_id: llm_txn.id, category_name: category.name }
    ] })

    assert_difference "DebugLogEntry.count", 2 do
      categorize([ cached_txn.id, llm_txn.id ])
    end

    entries = DebugLogEntry.order(:created_at).last(2)
    cache_entry = entries.find { |entry| entry.message == "AI categorization cache used" }
    ai_entry = entries.find { |entry| entry.message == "AI categorization completed" }

    assert_equal [ cached_txn.id ], cache_entry.metadata["cached_transaction_ids"]
    assert_equal [ cached_txn.id, llm_txn.id ], ai_entry.metadata["requested_transaction_ids"]
    assert_equal [ cached_txn.id ], ai_entry.metadata["cached_transaction_ids"]
    assert_equal [ llm_txn.id ], ai_entry.metadata["categorized_transaction_ids"]
  end

  # Jev answers when the categorize route lists it: the instance's choice, read
  # by the deprecated ENV path. Preview gates whether the selector is offered (see
  # docs/llm-guides/gating-a-preview-feature.md), never what gets used.

  test "uses the LLM by default" do
    txn = create_transaction(account: @account, name: "Coffee shop").transaction
    category = @family.categories.create!(name: "Coffee")

    assert_equal "llm", with_ai_env({}) { Ai::LegacyEnvConfig.categorization_provider }
    requests = stub_ai(:categorize, returns: { categorizations: [
      { transaction_id: txn.id, category_name: category.name }
    ] })

    categorize([ txn.id ])

    assert_equal category, txn.reload.category
    assert_instance_of Ai::Transport::Base::Request, requests.sole
  end

  test "uses Jev when the categorize route lists it" do
    use_ai_routes(categorize: %w[jev/jev-latest])
    txn = create_transaction(account: @account, name: "Blue Bottle Coffee").transaction
    category = @family.categories.create!(name: "Coffee")
    requests = stub_ai(:categorize) { { txn.id => { category: [ category.name, 0.97 ] } } }

    categorize([ txn.id ])

    assert_equal category, txn.reload.category
    assert_instance_of Ai::Transport::Base::JudgeRequest, requests.sole
    assert_equal "jev", DebugLogEntry.order(:created_at).last.provider_key
  end

  test "the instance's Jev choice routes categorize to Jev, and its shadow to the LLM" do
    Ai::Config.override = nil
    Setting.categorization_provider = "jev"

    with_ai_env("OPENAI_ACCESS_TOKEN" => "sk-test", "JEV_API_KEY" => "jev-test") do
      assert_equal [ "jev" ], Ai.plan(:categorize, family: @family).routes.map { _1.endpoint.name }
      assert_equal [ "openai" ], Ai.plan(:shadow_categorize, family: @family).routes.map { _1.endpoint.name }
    end
  ensure
    Setting.categorization_provider = nil
  end

  test "falls back to the LLM when Jev is chosen but has no key" do
    Ai::Config.override = nil
    Setting.stubs(:jev_api_key).returns(nil)   # its default is the host's JEV_API_KEY, read at boot
    txn = create_transaction(account: @account, name: "Coffee shop").transaction
    category = @family.categories.create!(name: "Coffee")
    stub_ai(:categorize, returns: { categorizations: [ { transaction_id: txn.id, category_name: category.name } ] })

    with_ai_env("OPENAI_ACCESS_TOKEN" => "sk-test", "CATEGORIZATION_PROVIDER" => "jev") do
      assert_no_difference -> { DebugLogEntry.where(level: "error").count } do
        categorize([ txn.id ])
      end
    end

    assert_equal category, txn.reload.category
  end

  test "a Jev outage never falls back to the LLM: no LLM route is attempted" do
    Ai::Config.override = nil
    txn = create_transaction(account: @account, name: "Coffee shop").transaction
    requests = stub_ai(:categorize) { raise Ai::Error::Upstream, "Jev unreachable" }

    # A JEV_ENDPOINT inherited from the host (e.g. an OpenRouter decisions URL) would build a
    # different route; this test is about the default TypeSafe endpoint going down. Setting's
    # default is read from that same ENV at boot, so clear it too.
    Setting.stubs(:jev_endpoint).returns(nil)
    with_env_overrides("OPENAI_ACCESS_TOKEN" => "sk-test", "CATEGORIZATION_PROVIDER" => "jev", "JEV_API_KEY" => "test_api_key",
                       "JEV_ENDPOINT" => nil) do
      categorize([ txn.id ])
    end

    assert requests.any?, "the Jev route was attempted"
    assert requests.all? { _1.is_a?(Ai::Transport::Base::JudgeRequest) },
         "no LLM request was attempted: #{requests.map { |r| r.class.name }.inspect}"
  end

  # Confidence has to change behaviour, not just appear in logs. Below the threshold the answer
  # is withheld and the transaction is left unlocked, so a later run can still correct it. Only
  # a model with calibrated confidence is gated.

  test "withholds a calibrated answer that carries no confidence at all" do
    @family.update!(categorization_confidence_threshold: 0.7)
    txn = create_transaction(account: @account, name: "Ambiguous thing").transaction
    category = @family.categories.create!(name: "Coffee")

    jev_returning(txn, RubyLLM::Choice.new(choice: category.name, probabilities: {}, confidence: nil))

    categorize([ txn.id ])

    assert_nil txn.reload.category
    assert_includes @account.transactions.reload.enrichable(:category_id), txn
  end

  test "a judge's low-confidence answer is withheld even when a fallback answered the rest of its batch" do
    @family.update!(categorization_confidence_threshold: 0.7)
    category = @family.categories.create!(name: "Coffee")
    low, big = 2.times.map { |i| create_transaction(account: @account, name: "Thing #{i}").transaction }
    use_ai_routes(categorize: %w[jev/jev-latest openai/gpt-4.1-mini])
    stub_ai(:categorize) do |request|
      if request.respond_to?(:states)
        raise Ai::Error::ContextTooLong, "too long" if request.states.key?(big.id)

        { low.id => { category: [ category.name, 0.2 ] } }
      else
        { categorizations: [ { transaction_id: big.id, category_name: category.name } ] }
      end
    end

    categorize([ low.id, big.id ])

    assert_nil low.reload.category, "Jev's 0.2 is below the threshold, whichever route answered last"
    assert_equal category, big.reload.category
  end

  test "applies every answer when the threshold is zero" do
    @family.update!(categorization_confidence_threshold: 0)
    txn = create_transaction(account: @account, name: "Ambiguous thing").transaction
    category = @family.categories.create!(name: "Coffee")

    assert_equal 0.0, @family.effective_categorization_confidence_threshold
    jev_returning(txn, [ category.name, 0.12 ])

    categorize([ txn.id ])

    assert_equal category, txn.reload.category
  end

  test "withholds an answer below the confidence threshold and leaves it retryable" do
    @family.update!(categorization_confidence_threshold: 0.7)
    txn = create_transaction(account: @account, name: "Ambiguous thing").transaction
    category = @family.categories.create!(name: "Coffee")

    jev_returning(txn, [ category.name, 0.52 ])

    assert_no_difference "DataEnrichment.count" do
      categorize([ txn.id ])
    end

    assert_nil txn.reload.category
    assert_includes @account.transactions.reload.enrichable(:category_id), txn

    entry = DebugLogEntry.order(:created_at).last
    withheld = entry.metadata["withheld_low_confidence"].sole
    assert_equal txn.id, withheld["transaction_id"]
    assert_in_delta 0.52, withheld["confidence"], 0.001
  end

  test "applies an answer at or above the confidence threshold" do
    @family.update!(categorization_confidence_threshold: 0.7)
    txn = create_transaction(account: @account, name: "Blue Bottle Coffee").transaction
    category = @family.categories.create!(name: "Coffee")

    jev_returning(txn, [ category.name, 0.97 ])

    categorize([ txn.id ])

    assert_equal category, txn.reload.category
  end

  test "a threshold never suppresses a model without calibrated confidence" do
    # The LLMs return a bare category name, and a self-hosted judge hasn't had its confidence
    # checked. Gating them on it would silently stop categorizing.
    @family.update!(categorization_confidence_threshold: 0.9)
    txn = create_transaction(account: @account, name: "Coffee shop").transaction
    category = @family.categories.create!(name: "Coffee")

    stub_ai(:categorize, returns: { categorizations: [ { transaction_id: txn.id, category_name: category.name } ] })
    categorize([ txn.id ])
    assert_equal category, txn.reload.category

    other = create_transaction(account: @account, name: "Coffee again").transaction
    local = Ai::Config::Endpoint.new(name: :jev_local, protocol: :jev, preset: :jev_local, base_url: "http://jev:8080", location: :local)
    Ai::Config.override = AiTestHelper.build_ai_config([ Ai::Config::Model.new(endpoint: local, name: "jev-latest", capabilities: %i[judge]) ],
                                                       { categorize: [ "jev_local/jev-latest" ] })
    stub_ai(:categorize) { { other.id => { category: [ category.name, 0.3 ] } } }
    categorize([ other.id ])
    assert_equal category, other.reload.category
  end

  test "a rule run over several windows counts skipped transactions as handled and finishes at zero" do
    use_ai_model_settings(batch_size: 2)
    category = @family.categories.create!(name: "Shops")
    txns = 8.times.map { |i| create_transaction(account: @account, name: "Shop #{i}").transaction }
    txns[1].update!(category:)                      # already categorized
    txns[2].lock_attr!(:category_id)                # the user's choice
    txns[6].update!(category:)
    txns[7].lock_attr!(:category_id)                # skipped ids at the end of the run
    open = txns.values_at(0, 3, 4, 5)
    rule_run = ai_rule_run(txns.size)
    sent = []
    stub_ai(:categorize) do |request|
      ids = request.schema.dig(:properties, :categorizations, :items, :properties, :transaction_id, :enum)
      sent << ids
      { categorizations: ids.map { { transaction_id: _1, category_name: category.name } } }
    end

    Ai::GenerationRun.enqueue(:categorize, family: @family, ids: txns.map(&:id), rule_run_id: rule_run.id)
    ActiveJob::Base.execute(enqueued_jobs.shift.stringify_keys) until enqueued_jobs.empty?

    assert_equal open.map(&:id).each_slice(2).to_a, sent, "items reach the model in the order they were queued"
    assert_equal [ 0, 4, "success" ], rule_run.reload.values_at(:transactions_awaiting_ai, :transactions_modified, :status)
    assert_equal 0, Ai::GenerationRun.count
  end

  test "a run that gives up halfway releases the transactions no job read" do
    use_ai_model_settings(batch_size: 2)
    category = @family.categories.create!(name: "Shops")
    txns = 6.times.map { |i| create_transaction(account: @account, name: "Shop #{i}").transaction }
    rule_run = ai_rule_run(txns.size)
    calls = 0
    stub_ai(:categorize) do |request|
      raise Ai::Error::Unauthorized, "key revoked" if (calls += 1) > 1

      ids = request.schema.dig(:properties, :categorizations, :items, :properties, :transaction_id, :enum)
      { categorizations: ids.map { { transaction_id: _1, category_name: category.name } } }
    end

    Ai::GenerationRun.enqueue(:categorize, family: @family, ids: txns.map(&:id), rule_run_id: rule_run.id)
    ActiveJob::Base.execute(enqueued_jobs.shift.stringify_keys) until enqueued_jobs.empty?

    assert_equal [ 0, 2, "failed" ], rule_run.reload.values_at(:transactions_awaiting_ai, :transactions_modified, :status)
    assert_equal 0, Ai::GenerationRun.count
  end

  test "a window whose query raises partway releases what it read as well as what's left" do
    use_ai_model_settings(batch_size: 2)
    txns = 6.times.map { |i| create_transaction(account: @account, name: "Shop #{i}").transaction }
    rule_run = ai_rule_run(txns.size)
    # The first chunk matches nothing, so the window reads on, and the next chunk's query fails.
    Family::AutoCategorizer.any_instance.stubs(:scope_for).returns(Transaction.none).then.raises(Ai::Error::Unauthorized, "key revoked")

    Ai::GenerationRun.enqueue(:categorize, family: @family, ids: txns.map(&:id), rule_run_id: rule_run.id)
    ActiveJob::Base.execute(enqueued_jobs.shift.stringify_keys) until enqueued_jobs.empty?

    assert_equal [ 0, 0, "failed" ], rule_run.reload.values_at(:transactions_awaiting_ai, :transactions_modified, :status)
    entry = DebugLogEntry.where(category: "auto_categorization", message: "AI categorization failed").order(:created_at).last
    assert_equal txns.first(2).map(&:id), entry.metadata["requested_transaction_ids"]
  end

  private
    def ai_rule_run(count)
      RuleRun.create!(rule: rules(:one), execution_type: "manual", status: "pending", pending_jobs_count: 0,
                      transactions_queued: count, executed_at: Time.current).tap { _1.await_ai!(count) }
    end

    def categorize(transaction_ids)
      Ai::GenerationJob.perform_now(:categorize, ai_run_args(:categorize, ids: transaction_ids, family: @family))
    end

    # Routes categorize to the test setup's cloud Jev and has it give one answer.
    def jev_returning(transaction, answer)
      use_ai_routes(categorize: %w[jev/jev-latest])
      stub_ai(:categorize) { { transaction.id => { category: answer } } }
    end

    # The host's AI variables cleared, so its CATEGORIZATION_PROVIDER or keys can't change the result.
    def with_ai_env(env, &) = with_env_overrides(AiLegacySetups::CONTROLLED.index_with { nil }.merge(env), &)
end
