require "test_helper"

class Settings::ClassifiersControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @admin = users(:family_admin)
    @family = @admin.family
  end

  test "admin can view the classifier settings" do
    sign_in @admin
    get settings_classifier_path

    assert_response :success
    assert_select "input[type=checkbox][name='bayes_settings[merchant_name_words]'][checked]"
    assert_select "input[type=hidden][name='bayes_settings[word_split]'][value='ascii']"
    assert_select "input[name='bayes_settings[threshold]'][value='0.7']"
    assert_select "input[name='included_category_ids[]']", count: @family.categories.count
    assert_select "#classifier_evaluation"
    # The fixture family has no classifier rules, so both switches are off.
    assert_select "input[type=checkbox][role=switch][name='active']:not([checked])", count: 2
    assert_select ".translation_missing", count: 0
    assert_select "span", text: I18n.t("settings.classifiers.category_training.exclude_transfers_hint")
  end

  test "non-admin member cannot view the classifier settings" do
    sign_in users(:family_member)
    get settings_classifier_path

    assert_redirected_to accounts_path
  end

  test "each section's update keeps the other sections' settings" do
    sign_in @admin

    patch settings_classifier_path, params: { bayes_settings: { bigrams: "1", threshold: "0.6" } }
    patch settings_classifier_path, params: { bayes_settings: { complement: "1" } }

    assert_redirected_to settings_classifier_path
    settings = @family.reload.bayes_settings_object
    assert settings.bigrams
    assert_equal 0.6, settings.threshold
    assert settings.complement
  end

  test "out-of-range values are clamped and unknown keys ignored" do
    sign_in @admin

    patch settings_classifier_path, params: { bayes_settings: { threshold: "5", max_training_transactions: "1", nonsense: "1" } }

    assert_equal({ "threshold" => 0.99, "max_training_transactions" => 100 }, @family.reload.bayes_settings)
  end

  test "the category checklist saves what's unchecked, respecting the cascade" do
    sign_in @admin
    parent = @family.categories.create!(name: "Parent")
    kept_child = @family.categories.create!(name: "Kept child", parent: parent)
    dropped_child = @family.categories.create!(name: "Dropped child", parent: parent)
    others = @family.categories.where.not(id: [ parent.id, kept_child.id, dropped_child.id ]).pluck(:id)

    # A partly checked parent isn't submitted, but isn't excluded either.
    patch settings_classifier_path, params: { category_filter: "1", included_category_ids: others + [ kept_child.id ] }

    assert_equal [ dropped_child.id.to_s ], @family.reload.bayes_settings_object.excluded_category_ids
  end

  test "reset clears every setting and tests the defaults" do
    @family.update_bayes_settings!(bigrams: "1")
    sign_in @admin

    assert_enqueued_with(job: BayesEvaluationJob, args: [ @family, { action: "reset" } ]) do
      patch settings_classifier_path, params: { reset: "1" }
    end

    assert_equal({}, @family.reload.bayes_settings)
    assert_redirected_to settings_classifier_path(anchor: "classifier_evaluation")
  end

  test "a rule's switch offers to add its rule when there's none, then turns it off and on" do
    sign_in @admin
    name = I18n.t("rules.classifier_rules.category_classifier")
    title = I18n.t("settings.classifiers.show.add_rule_title", name: name)

    patch rule_settings_classifier_path, params: { action_type: "bayes_categorize", active: "1" }
    assert_redirected_to settings_classifier_path(add_rule: "bayes_categorize")
    get settings_classifier_path(add_rule: "bayes_categorize")
    assert_select "dialog", text: /#{Regexp.escape(title)}/

    assert_difference -> { @family.rules.count }, 1 do
      post add_rule_settings_classifier_path, params: { action_type: "bayes_categorize" }
    end
    rule = @family.classifier_rules("bayes_categorize").sole
    assert rule.active?
    assert_equal 1, rule.position

    patch rule_settings_classifier_path, params: { action_type: "bayes_categorize", active: "0" }
    assert_not rule.reload.active?
    patch rule_settings_classifier_path, params: { action_type: "bayes_categorize", active: "1" }
    assert rule.reload.active?
    # With the rule there, the question isn't asked.
    get settings_classifier_path(add_rule: "bayes_categorize")
    assert_select "dialog", text: /#{Regexp.escape(title)}/, count: 0
  end

  test "a rule's switch only knows the matcher and Bayes" do
    sign_in @admin

    patch rule_settings_classifier_path, params: { action_type: "auto_categorize", active: "1" }

    assert_response :bad_request
  end

  test "run and clear locks queue their jobs" do
    sign_in @admin

    assert_enqueued_with(job: BayesCategorizeJob, args: [ @family ]) do
      post run_settings_classifier_path
    end
    assert_redirected_to settings_classifier_path

    assert_enqueued_with(job: ClearBayesLocksJob, args: [ @family ]) do
      post clear_locks_settings_classifier_path
    end
    assert_redirected_to settings_classifier_path
  end

  test "test my settings and find best settings queue their run" do
    sign_in @admin

    assert_enqueued_with(job: BayesEvaluationJob, args: [ @family, { action: "test" } ]) do
      post evaluate_settings_classifier_path
    end
    assert_redirected_to settings_classifier_path(anchor: "classifier_evaluation")

    assert_enqueued_with(job: BayesEvaluationJob, args: [ @family, { action: "find_best" } ]) do
      post find_best_settings_classifier_path
    end
  end

  test "no second run while one is running" do
    Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)
    sign_in @admin
    Family::BayesEvaluation.mark_running!(@family)

    assert_no_enqueued_jobs only: BayesEvaluationJob do
      post evaluate_settings_classifier_path
      post find_best_settings_classifier_path
    end
    assert_redirected_to settings_classifier_path(anchor: "classifier_evaluation")
  end

  test "the cost of a mistake is saved as it changes, within its range" do
    Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)
    sign_in @admin

    assert_no_enqueued_jobs do
      post remember_weight_settings_classifier_path, params: { weight: "9" }
    end

    assert_redirected_to settings_classifier_path(anchor: "classifier_evaluation")
    assert_equal 3, Family::BayesEvaluation.weight(@family)
  end

  test "apply saves the matcher's best cell with Find best settings' result, and nothing after only a test" do
    Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)
    sign_in @admin
    row = ->(similarity, right) { { "threshold" => similarity, "right" => right, "wrong" => 1 } }
    tested = {
      "version" => Family::BayesEvaluation::RESULT_VERSION, "digest" => @family.bayes_settings_object.digest,
      "current" => { "threshold" => 0.7 },
      "matcher" => { "n" => 12, "cutoffs" => { 0.1 => { 1 => [ row.call(0.9, 9) ], 2 => [ row.call(0.9, 8) ], 3 => [ row.call(0.85, 10), row.call(0.9, 7) ] } } }
    }
    Rails.cache.write(Family::BayesEvaluation.cache_key(@family), tested)

    assert_no_enqueued_jobs do
      patch apply_best_settings_classifier_path
    end
    assert_equal({}, @family.reload.bayes_settings)

    # Find best found nothing better for the categories: only the matcher changes.
    found = tested.merge("best" => { "changes" => {}, "report" => { "sweep" => [ { "threshold" => 0.7, "right" => 1, "wrong" => 0 } ] } })
    Rails.cache.write(Family::BayesEvaluation.cache_key(@family), found)
    assert_enqueued_with(job: BayesEvaluationJob, args: [ @family, { action: "test" } ]) do
      patch apply_best_settings_classifier_path
    end
    assert_equal({ "similar_common_share" => 0.1, "similar_min_neighbours" => 3, "similar_threshold" => 0.85 }, @family.reload.bayes_settings)
  end

  test "the page shows the matcher's table, without Best found after a test" do
    Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)
    sign_in @admin
    report = { "n" => 1, "threshold" => 0.7, "sweep" => [ { "threshold" => 0.7, "right" => 1, "wrong" => 0 } ], "confusions" => {}, "uncategorized" => {} }
    sweep = [ { "threshold" => 0.9, "right" => 5, "wrong" => 1, "confusions" => [], "unfilled" => [] } ]
    Rails.cache.write(Family::BayesEvaluation.cache_key(@family), {
      "version" => Family::BayesEvaluation::RESULT_VERSION, "action" => "test", "digest" => @family.bayes_settings_object.digest,
      "ran_at" => Time.current.iso8601, "months" => %w[2026-08 2026-09], "current" => report, "defaults" => report,
      "matcher" => { "n" => 6, "cutoffs" => { 0.2 => { 1 => sweep, 2 => sweep, 3 => sweep } } }
    })

    get settings_classifier_path

    # After a test, both tables have My settings and Defaults, and no Best found.
    %w[current defaults].each { |column| assert_select "#classifier_evaluation th", text: I18n.t("settings.classifiers.evaluation.#{column}"), count: 2 }
    assert_select "#classifier_evaluation th", text: I18n.t("settings.classifiers.evaluation.best"), count: 0
    assert_select "#classifier_evaluation th", text: I18n.t("settings.classifiers.evaluation.similarity")
    assert_select "h2", text: I18n.t("settings.classifiers.show.matcher_tuning")
    # Each column's best row in bold: 0.7 in the category table's two, 0.9 in the matcher's.
    assert_select "#classifier_evaluation td span.font-medium", count: 4
    assert_select ".translation_missing", count: 0
  end

  test "the page shows the three columns, the buttons in their order, and the best found's mistakes" do
    Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)
    sign_in @admin
    report = ->(threshold) {
      { "n" => 10, "threshold" => threshold, "sweep" => [ { "threshold" => 0.4, "right" => 8, "wrong" => 1 }, { "threshold" => 0.8, "right" => 6, "wrong" => 0 } ],
        "confusions" => { 0.4 => [ [ "Coffee", "Groceries", 1 ] ], 0.8 => [] }, "uncategorized" => { 0.4 => [ [ "Splurge", 2 ] ], 0.8 => [] } }
    }
    Rails.cache.write(Family::BayesEvaluation.cache_key(@family), {
      "version" => Family::BayesEvaluation::RESULT_VERSION, "action" => "find_best", "digest" => @family.bayes_settings_object.digest,
      "ran_at" => Time.current.iso8601, "months" => %w[2026-08 2026-09], "current" => report.call(0.7), "defaults" => report.call(0.7),
      "best" => { "changes" => { "binary" => true }, "report" => report.call(0.7) }
    })

    get settings_classifier_path

    assert_select "#classifier_evaluation th", text: I18n.t("settings.classifiers.evaluation.current")
    assert_select "#classifier_evaluation th", text: I18n.t("settings.classifiers.evaluation.best")
    assert_select "#classifier_evaluation th", text: I18n.t("settings.classifiers.evaluation.defaults")
    buttons = css_select("#classifier_evaluation button").map { |button| button.text.strip }
    labels = %w[run find_best reset apply_best].map { |key| I18n.t("settings.classifiers.evaluation.#{key}") }
    assert_equal labels, buttons & labels
    # At a cost of 1, 0.4 scores 7 and 0.8 scores 6: Apply would set 0.4.
    assert_select "li", text: /Coffee → Groceries/
    assert_select "li", text: /2\s+Splurge/
    assert_select ".translation_missing", count: 0
  end

  test "with too little history the page warns and Apply stays off" do
    Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)
    sign_in @admin
    report = { "n" => 0, "threshold" => 0.7, "sweep" => [ { "threshold" => 0.7, "right" => 0, "wrong" => 0 } ], "confusions" => {}, "uncategorized" => {} }
    Rails.cache.write(Family::BayesEvaluation.cache_key(@family), {
      "version" => Family::BayesEvaluation::RESULT_VERSION, "action" => "find_best", "digest" => @family.bayes_settings_object.digest,
      "ran_at" => Time.current.iso8601, "months" => %w[2026-08 2026-09], "current" => report, "defaults" => report,
      "best" => { "changes" => { "binary" => true }, "report" => report }, "short_history" => true
    })

    get settings_classifier_path

    assert_select "#classifier_evaluation", text: /#{Regexp.escape(I18n.t("settings.classifiers.evaluation.short_history", months: Family::BayesEvaluation::MONTHS))}/
    assert_select "#classifier_evaluation button[disabled]", text: I18n.t("settings.classifiers.evaluation.apply_best")
  end

  test "apply saves the best found at the threshold for the chosen cost and tests it, unless the settings changed since" do
    Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)
    sign_in @admin
    best = { "changes" => { "binary" => true },
             "report" => { "sweep" => [ { "threshold" => 0.4, "right" => 10, "wrong" => 2 }, { "threshold" => 0.8, "right" => 7, "wrong" => 0 } ] } }
    result = { "version" => Family::BayesEvaluation::RESULT_VERSION, "current" => { "threshold" => 0.7 }, "best" => best }
    Rails.cache.write(Family::BayesEvaluation.cache_key(@family), result.merge("digest" => "stale"))

    assert_no_enqueued_jobs do
      patch apply_best_settings_classifier_path
    end
    assert_equal({}, @family.reload.bayes_settings)

    # A mistake costs 2: 0.4 scores 6, 0.8 scores 7.
    Family::BayesEvaluation.remember_weight!(@family, 2)
    Rails.cache.write(Family::BayesEvaluation.cache_key(@family), result.merge("digest" => @family.bayes_settings_object.digest))
    assert_enqueued_with(job: BayesEvaluationJob, args: [ @family, { action: "test" } ]) do
      patch apply_best_settings_classifier_path
    end
    assert_equal({ "threshold" => 0.8, "binary" => true }, @family.reload.bayes_settings)
  end
end
