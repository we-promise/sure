require "test_helper"

class Family::BayesEvaluationTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = Family.create!(name: "Evaluation family")
    @account = @family.accounts.create!(name: "Evaluation", balance: 0, currency: "USD", accountable: Depository.new)
    @coffee = @family.categories.create!(name: "Coffee")
    @groceries = @family.categories.create!(name: "Groceries")
    @today = Date.new(2026, 10, 17)
    history = Date.new(2026, 1, 15)
    10.times { create_transaction(account: @account, name: "Starbucks Coffee", category: @coffee, date: history) }
    10.times { create_transaction(account: @account, name: "Safeway Groceries", category: @groceries, date: history) }
    Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)
  end

  test "scores the newest months on what came before, without writing anything" do
    create_transaction(account: @account, name: "Starbucks Coffee", category: @coffee, date: Date.new(2026, 9, 3))
    create_transaction(account: @account, name: "Safeway Groceries", category: @coffee, date: Date.new(2026, 9, 4))
    # Still on a Bayes guess, so not a fair test row.
    guessed = create_transaction(account: @account, name: "Starbucks Coffee", date: Date.new(2026, 9, 5)).transaction
    guessed.enrich_attribute(:category_id, @coffee.id, source: "bayes")

    result = nil
    assert_no_difference "DataEnrichment.count" do
      result = Family::BayesEvaluation.new(@family, today: @today).run!
    end

    assert_equal %w[2026-08 2026-09], result["months"]
    assert_equal "test", result["action"]
    assert_equal 2, result.dig("current", "n")
    at_threshold = result.dig("current", "sweep").find { |row| row["threshold"] == 0.4 }
    assert_equal({ "threshold" => 0.4, "right" => 1, "wrong" => 1 }, at_threshold)
    assert_equal [ [ "Coffee", "Groceries", 1 ] ], result.dig("current", "confusions", 0.7)
    assert_equal result["current"], result["defaults"]
    assert_nil result["best"]
  end

  test "scores the matcher on the same months, by similarity and number agreeing" do
    netflix = @family.merchants.create!(name: "Netflix")
    hulu = @family.merchants.create!(name: "Hulu")
    2.times { create_transaction(account: @account, name: "NETFLIX.COM 8812", merchant: netflix, date: Date.new(2026, 7, 1)) }
    create_transaction(account: @account, name: "Netflix com 1203", merchant: netflix, date: Date.new(2026, 9, 2))
    # Copied from near-duplicates of Netflix, but it's Hulu: one wrong at 1 agreeing.
    create_transaction(account: @account, name: "NETFLIX COM", merchant: hulu, date: Date.new(2026, 8, 2))
    # A transfer is neither tested nor copied from.
    create_transaction(account: @account, name: "Netflix com", merchant: hulu, kind: "funds_movement", date: Date.new(2026, 9, 3))

    matcher = Family::BayesEvaluation.new(@family, today: @today).run!["matcher"]

    assert_equal 2, matcher["n"]
    assert_equal Family::BayesSettings::STEPS[:similar_common_share], matcher["cutoffs"].keys
    at = ->(agreeing, similarity) { matcher.dig("cutoffs", 0.2, agreeing).find { |row| row["threshold"] == similarity }.values_at("right", "wrong") }
    # Aug: Hulu against 2 Netflix → wrong. Sep: Netflix against 2 Netflix and
    # the Hulu → disagree, so nothing.
    assert_equal [ 0, 1 ], at.call(1, 0.9)
    assert_equal [ 0, 1 ], at.call(2, 0.9)
    assert_equal [ 0, 0 ], at.call(3, 0.9)
    row = matcher.dig("cutoffs", 0.2, 1).find { |r| r["threshold"] == 0.9 }
    assert_equal [ [ "Hulu", "Netflix", 1 ] ], row["confusions"]
    assert_equal [ [ "Netflix", 1 ] ], row["unfilled"]
  end

  test "the matcher's mistakes are listed for the button pressed last, at that column's similarity" do
    row = ->(similarity, right, wrong) { { "threshold" => similarity, "right" => right, "wrong" => wrong, "confusions" => [ [ "A", "B", wrong ] ] } }
    cutoffs = { 0.2 => { 2 => [ row.call(0.8, 5, 1), row.call(0.9, 4, 0) ] }, 0.05 => { 1 => [ row.call(0.65, 20, 2) ] } }
    settings = Family::BayesSettings.new(similar_threshold: 0.8)
    mistakes = ->(action) { Family::BayesEvaluation.matcher_mistakes({ "action" => action, "best" => {}, "matcher" => { "cutoffs" => cutoffs } }, settings, 1) }

    assert_equal [ "current", 0.8, cutoffs.dig(0.2, 2, 0) ], mistakes.call("test")
    assert_equal [ "best", 0.65, cutoffs.dig(0.05, 1, 0) ], mistakes.call("find_best")
    assert_equal [ "defaults", 0.9, cutoffs.dig(0.2, 2, 1) ], mistakes.call("reset")
    assert_nil Family::BayesEvaluation.matcher_mistakes({}, settings, 1)
  end

  test "apply's matcher changes: the one best cell over every cutoff; on a tie the most agreeing, then highest similarity, then cutoff" do
    row = ->(similarity, right, wrong) { { "threshold" => similarity, "right" => right, "wrong" => wrong } }
    sweeps = {
      1 => [ row.call(0.8, 12, 4), row.call(0.9, 11, 3) ],
      2 => [ row.call(0.8, 10, 2), row.call(0.9, 9, 1) ],
      3 => [ row.call(0.8, 8, 0), row.call(0.9, 7, 0) ]
    }
    result = { "best" => { "changes" => {} },
               "matcher" => { "cutoffs" => { 0.1 => sweeps, 0.2 => sweeps, 0.4 => sweeps.merge(1 => [ row.call(0.9, 20, 1) ]) } } }
    settings = Family::BayesSettings.new

    # Cost 1: 0.4's 1-agreeing 0.9 scores 19, beating every other cell.
    assert_equal [ 0.4, 1, 0.9 ], Family::BayesEvaluation.best_matcher(result, 1)
    assert_equal({ "similar_common_share" => 0.4, "similar_min_neighbours" => 1 }, Family::BayesEvaluation.matcher_changes(result, settings, 1))
    # Only after Find best settings, as for the categories.
    assert_equal({}, Family::BayesEvaluation.apply_changes(result.except("best"), settings, 1))
    # Too little history for the categories still applies the matcher's, but not when it scored nothing.
    assert_equal [ "similar_common_share", "similar_min_neighbours" ], Family::BayesEvaluation.apply_changes(result.merge("short_history" => true), settings, 1).keys
    assert_equal({}, Family::BayesEvaluation.matcher_changes(result.merge("matcher" => result["matcher"].merge("n" => 0)), settings, 1))
    # Without it, every 1- and 2-agreeing cell and 3 at 0.8 score 8: 3 at 0.8, at the highest cutoff.
    result["matcher"]["cutoffs"][0.4] = sweeps
    assert_equal [ 0.4, 3, 0.8 ], Family::BayesEvaluation.best_matcher(result, 1)
    assert_equal({}, Family::BayesEvaluation.matcher_changes({}, settings, 1))
  end

  test "the matcher's columns: yours, the best found for the cost after Find best settings, and the defaults" do
    row = ->(similarity, right, wrong) { { "threshold" => similarity, "right" => right, "wrong" => wrong } }
    result = { "best" => { "changes" => {} }, "matcher" => { "cutoffs" => {
      0.05 => { 1 => [ row.call(0.65, 20, 5), row.call(0.9, 15, 1) ], 2 => [ row.call(0.9, 10, 0) ] },
      0.2 => { 2 => [ row.call(0.9, 9, 1) ] }
    } } }
    settings = Family::BayesSettings.new(similar_common_share: 0.03)

    columns = ->(weight) { Family::BayesEvaluation.matcher_columns(result, settings, weight).map { |c| c.first(3) } }
    # Cost 1 or 3, 0.05 with 1 agreeing has the best cell. A cutoff typed in
    # that wasn't scored has no rows.
    assert_equal [ [ "current", 0.03, 2 ], [ "best", 0.05, 1 ], [ "defaults", 0.2, 2 ] ], columns.call(1)
    assert_equal [ "best", 0.05, 1 ], columns.call(3)[1]
    assert_equal [], Family::BayesEvaluation.matcher_columns(result, settings, 1).first[3]
    # Best found only after Find best settings.
    assert_equal %w[current defaults], Family::BayesEvaluation.matcher_columns(result.except("best"), settings, 1).map(&:first)
    assert_nil Family::BayesEvaluation.matcher_columns({}, settings, 1)
  end

  test "caches the latest result and compares with the defaults" do
    create_transaction(account: @account, name: "Starbucks Coffee", category: @coffee, date: Date.new(2026, 9, 3))
    @family.update_bayes_settings!(threshold: "0.65")
    settings = @family.bayes_settings_object

    result = Family::BayesEvaluation.new(@family, today: @today).run!

    assert_includes result.dig("current", "sweep").map { |row| row["threshold"] }, 0.65
    assert_not_includes result.dig("defaults", "sweep").map { |row| row["threshold"] }, 0.65
    assert_equal result, Family::BayesEvaluation.cached(@family)
    assert_equal settings.digest, result["digest"]
  end

  test "the defaults keep the chosen categories, so both score the same transactions" do
    create_transaction(account: @account, name: "Starbucks Coffee", category: @coffee, date: Date.new(2026, 9, 3))
    create_transaction(account: @account, name: "Safeway Groceries", category: @groceries, date: Date.new(2026, 9, 4))
    @family.update_bayes_settings!(excluded_category_ids: [ @groceries.id ], threshold: "0.65")

    result = Family::BayesEvaluation.new(@family, today: @today).run!

    assert_equal 1, result.dig("current", "n")
    assert_equal 1, result.dig("defaults", "n")
    assert_equal 0.7, result.dig("defaults", "threshold")
  end

  test "ROC-AUC ranks each category's rows against the rest, weighted by its rows" do
    # Coffee's rows score 0.9 and 0.5, the tea row 0.5 for coffee: one win,
    # one tie of two → 0.75. Tea's one row outranks both coffee rows → 1.0.
    rows = [ [ "coffee", { "coffee" => 0.9, "tea" => 0.1 } ],
             [ "coffee", { "coffee" => 0.5, "tea" => 0.5 } ],
             [ "tea", { "coffee" => 0.5, "tea" => 0.6 } ] ]

    assert_in_delta (2 * 0.75 + 1 * 1.0) / 3, Family::BayesEvaluation.roc_auc(rows)
    assert_nil Family::BayesEvaluation.roc_auc([ [ "coffee", {} ] ])
  end

  test "a transaction it doesn't answer counts as no information in the AUC" do
    create_transaction(account: @account, name: "Starbucks Coffee", category: @coffee, date: Date.new(2026, 9, 3))
    create_transaction(account: @account, name: "Zzyzx", category: @groceries, date: Date.new(2026, 9, 4))
    create_transaction(account: @account, name: "Safeway Groceries", category: @coffee, date: Date.new(2026, 9, 5))
    evaluation = Family::BayesEvaluation.new(@family, today: @today, months: 1)

    # Zzyzx isn't answered, so it scores 0.5 for both. Coffee's rows,
    # Starbucks (~1) and Safeway (~0), against it: one win, one loss.
    # Groceries' Zzyzx against Starbucks (~0) and Safeway (~1): the same.
    report = evaluation.report
    assert_equal 3, report["n"]
    assert_equal 2, report["sweep"].first.values_at("right", "wrong").sum
    assert_in_delta 0.5, report["auc"]
    assert_equal [ [ "Groceries", 1 ] ], report.dig("uncategorized", 0.7)
  end

  test "report scores any settings over the chosen months, uncached" do
    create_transaction(account: @account, name: "Starbucks Coffee", category: @coffee, date: Date.new(2026, 9, 3))
    evaluation = Family::BayesEvaluation.new(@family, today: @today, months: 1)

    report = evaluation.report(Family::BayesSettings.new(threshold: 0.5))

    assert_equal [ "2026-09" ], evaluation.month_labels
    assert_equal 1, report["n"]
    assert_equal [ report["auc"] ], report["month_aucs"]
    assert_equal 0.5, report["threshold"]
    assert_nil Family::BayesEvaluation.cached(@family)
  end

  test "search fixes the features, then the parameters, then the threshold" do
    evaluation = fake_reports(tuned_evaluation)
    # Amount and account help only together, so one at a time would never
    # find them; reading neither the merchant's name nor the notes helps.
    FakeEvaluation.bonus = ->(settings) {
      fields = [ settings.amount_field, settings.account_field ].count(true)
      words = [ settings.merchant_name_words, settings.include_notes ].count(false)
      { 0 => 0, 1 => -0.01, 2 => 0.03 }[fields] + { 0 => 0, 1 => -0.005, 2 => 0.005 }[words]
    }
    tried = []

    best, report = evaluation.search { |changes| tried << changes }

    assert best.amount_field
    assert best.account_field
    assert_not best.merchant_field
    assert_not best.merchant_name_words
    assert_not best.include_notes
    # Then by AUC binary +0.02, then dropping the prior +0.01. The threshold
    # isn't searched; picked afterwards from the result's sweep, it's
    # binary's 0.8, not the 0.4 the starting settings would pick.
    assert best.binary
    assert_not best.prior
    assert_equal 0.4, best.threshold
    assert_equal 0.8, Family::BayesEvaluation.best_threshold(report["sweep"], 3)

    assert_includes tried, { amount_field: true, account_field: true }
    assert_includes tried, { separate_fields: true }
    assert_includes tried, { smoothing: 0.1 }
    assert_not_includes tried, { smoothing: 1.0 }
    features = Family::BayesEvaluation::FEATURE_SETS.flatten
    first_parameter = tried.index { |changes| (changes.keys & features).empty? }
    assert tried.drop(first_parameter).none? { |changes| changes.keys.intersect?(features) }, "a feature was tried again after step 1"
    assert_operator tried.rindex { |changes| changes.key?(:binary) }, :<, tried.index { |changes| changes.key?(:prior) }
  end

  test "the threshold is the shown table's best row for the cost of a mistake" do
    # A real Best found, over two months.
    sweep = [ [ 0.2, 313, 35 ], [ 0.3, 302, 27 ], [ 0.4, 292, 24 ], [ 0.5, 286, 22 ],
              [ 0.6, 281, 20 ], [ 0.7, 273, 16 ], [ 0.8, 266, 11 ], [ 0.9, 251, 9 ] ]
              .map { |threshold, right, wrong| { "threshold" => threshold, "right" => right, "wrong" => wrong } }
    result = { "current" => { "threshold" => 0.7 }, "best" => { "changes" => {}, "report" => { "sweep" => sweep } } }

    assert_equal 0.2, Family::BayesEvaluation.best_changes(result, 1)["threshold"]
    assert_equal 0.3, Family::BayesEvaluation.best_changes(result, 2)["threshold"]
    assert_equal 0.8, Family::BayesEvaluation.best_changes(result, 3)["threshold"]
  end

  test "the threshold is picked for the cost of a mistake, the highest on a tie" do
    sweep = [ { "threshold" => 0.4, "right" => 120, "wrong" => 20 },
              { "threshold" => 0.8, "right" => 100, "wrong" => 8 },
              { "threshold" => 0.9, "right" => 98, "wrong" => 7 } ]

    assert_equal 0.4, Family::BayesEvaluation.best_threshold(sweep, 1)
    # 84 at both 0.8 and 0.9.
    assert_equal 0.9, Family::BayesEvaluation.best_threshold(sweep, 2)
    assert_equal 0.9, Family::BayesEvaluation.best_threshold(sweep, 3)
  end

  test "search keeps a change only when it's better in all but one month" do
    evaluation = fake_reports(tuned_evaluation)
    # Over 6 months: word pairs gain a lot in 3 and lose a little in 3, so
    # more overall; dropping codes gains in 5 of them.
    FakeEvaluation.month_bonus = ->(settings, i) {
      (settings.bigrams ? (i < 3 ? 0.04 : -0.01) : 0) + (settings.drop_codes ? (i < 5 ? 0.01 : -0.01) : 0)
    }

    best, = evaluation.search

    assert_not best.bigrams
    assert best.drop_codes
  end

  test "search doesn't try a setting that does nothing while another is off" do
    evaluation = fake_reports(tuned_evaluation(amount_field: false))
    tried = []

    evaluation.search { |changes| tried.concat(changes.keys) }

    assert_includes tried, :amount_field
    assert_not_includes tried, :amount_by_direction
    assert_not_includes tried, :separate_fields
  end

  test "find best searches the older months and scores the best found on the newest, unseen" do
    evaluation = fake_reports(tuned_evaluation)

    result = evaluation.run!(action: "find_best")

    assert_equal [ %w[2026-04 2026-05 2026-06 2026-07] ], FakeEvaluation.searched
    assert_equal %w[2026-08 2026-09], result["months"]
    assert_equal({ "binary" => true, "prior" => false }, result.dig("best", "changes"))
    assert_equal 0.4, result.dig("current", "threshold")
    assert_equal({ "binary" => true, "prior" => false, "threshold" => 0.8 }, Family::BayesEvaluation.best_changes(result, 3))
  end

  test "too little history keeps Apply off: nothing tested, or too few months for the search" do
    assert Family::BayesEvaluation.new(@family, today: @today).run!["short_history"]

    evaluation = fake_reports(tuned_evaluation)
    settings = evaluation.send(:settings)
    result = evaluation.run!(action: "find_best")
    assert result["short_history"]
    assert_equal({}, Family::BayesEvaluation.apply_changes(result, settings, 1))

    # Three of the four searched months, each with history before it: enough.
    [ 4, 5, 6 ].each { |month| create_transaction(account: @account, name: "Starbucks Coffee", category: @coffee, date: Date.new(2026, month, 3)) }
    result = evaluation.run!(action: "find_best")
    assert_not result["short_history"]
    assert_not_empty Family::BayesEvaluation.apply_changes(result, settings, 1)
  end

  test "apply leaves the threshold alone when it's already the one picked" do
    result = { "current" => { "threshold" => 0.8 },
               "best" => { "changes" => { "binary" => true }, "report" => { "sweep" => [ { "threshold" => 0.8, "right" => 5, "wrong" => 0 } ] } } }

    assert_equal({ "binary" => true }, Family::BayesEvaluation.best_changes(result, 2))
  end

  test "the page lists the mistakes of whichever button was pressed last" do
    report = ->(threshold) { { "threshold" => threshold, "sweep" => [], "confusions" => { threshold => [ [ "A", "B", 1 ] ] } } }
    best = { "changes" => {}, "report" => report.call(0.4).merge("sweep" => [ { "threshold" => 0.4, "right" => 1, "wrong" => 0 },
                                                                            { "threshold" => 0.8, "right" => 1, "wrong" => 0 } ]) }
    result = { "current" => report.call(0.4), "defaults" => report.call(0.7), "best" => best }

    assert_equal [ "current", result["current"], 0.4 ], Family::BayesEvaluation.mistakes(result.merge("action" => "test"), 1)
    assert_equal [ "best", best["report"], 0.8 ], Family::BayesEvaluation.mistakes(result.merge("action" => "find_best"), 1)
    assert_equal [ "defaults", result["defaults"], 0.7 ], Family::BayesEvaluation.mistakes(result.merge("action" => "reset"), 1)
  end

  test "a cached result of an older shape is ignored" do
    Rails.cache.write(Family::BayesEvaluation.cache_key(@family), { "digest" => "old" })

    assert_nil Family::BayesEvaluation.cached(@family)
  end

  test "running flag clears when the run ends" do
    Family::BayesEvaluation.mark_running!(@family)
    assert Family::BayesEvaluation.running?(@family)

    Family::BayesEvaluation.new(@family, today: @today).run!

    assert_not Family::BayesEvaluation.running?(@family)
  end

  private
    def tuned_evaluation(**changes)
      Family::BayesEvaluation.new(@family, today: @today, settings: Family::BayesSettings.new(threshold: 0.4, prior: true, **changes))
    end

    def fake_reports(evaluation)
      FakeEvaluation.searched = []
      FakeEvaluation.bonus = ->(_) { 0 }
      FakeEvaluation.month_bonus = ->(_, _) { 0 }
      FakeEvaluation.new(@family, today: @today, settings: evaluation.send(:settings))
    end

    # Reports by rule, for any months: binary +10 right and +0.02 AUC, no
    # prior +3 right and +0.01 AUC; at 0.4, 10 more right than at 0.8 and 2
    # more wrong, or 10 with binary; bonus adds to the AUC, month_bonus to
    # one month's (and so to the mean, the overall AUC). Records the months
    # each search ran over.
    class FakeEvaluation < Family::BayesEvaluation
      cattr_accessor :searched, :bonus, :month_bonus

      def report(settings = self.settings)
        right = (settings.binary ? 100 : 90) + (settings.prior ? 0 : 3)
        auc = 0.8 + (settings.binary ? 0.02 : 0) + (settings.prior ? 0 : 0.01) + bonus.call(settings)
        month_aucs = month_labels.each_index.map { |i| auc + month_bonus.call(settings, i) }
        { "n" => 200, "threshold" => settings.threshold, "auc" => month_aucs.sum / month_aucs.size, "month_aucs" => month_aucs, "confusions" => [],
          "sweep" => [ { "threshold" => 0.4, "right" => right + 10, "wrong" => settings.binary ? 20 : 12 },
                       { "threshold" => 0.8, "right" => right, "wrong" => 10 } ] }
      end

      def search(&)
        searched << month_labels
        super
      end
    end
end
