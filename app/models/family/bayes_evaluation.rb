# Monthly time-split evaluation of Family::BayesCategorizer on the family's
# own history, for Settings → Classifier. For each month it trains on what
# came before (as of the day before the month starts) and classifies that
# month's categorized transactions whose category isn't an automatic (Bayes
# or AI) guess, comparing with what they're categorized as. It only reads:
# classify never writes. The page scores the newest HOLDOUT_MONTHS of the
# last MONTHS; "Find best settings" searches the months before them, so the
# best found is scored on months it never saw (see search). The latest
# result is cached, with the defaults alongside for comparison and the
# digest of the settings it tested. The defaults keep the chosen categories,
# so every column scores the same transactions. Each run also
# scores the matcher (Family::SimilarMerchantFiller) on the same months, at
# every cutoff, similarity and number agreeing it offers (matcher_report).
class Family::BayesEvaluation
  MONTHS = 6
  HOLDOUT_MONTHS = 2
  THRESHOLDS = [ 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9 ].freeze
  CACHE_TTL = 30.days
  RUNNING_TTL = 15.minutes
  TOP_CONFUSIONS = 3
  # Picks the threshold Apply sets: a wrong answer costs this many right ones.
  WEIGHTS = 1..3
  DEFAULT_WEIGHT = 1
  # What ran: Test my settings, Find best settings, or Reset to defaults
  # (which tests the defaults).
  ACTIONS = %w[test find_best reset].freeze
  # Bumped when the cached result's shape changes, so an older one is ignored.
  RESULT_VERSION = 9
  # The matcher's settings: not searched; picked on the page from its own
  # table (matcher_changes).
  MATCHER_KEYS = %i[similar_threshold similar_min_neighbours similar_common_share].freeze
  # The settings it tunes, by page section (for their labels): the on/off
  # ones, and the word split and smoothing at SEARCH_STEPS. Not grace days:
  # they're measured from today, not each month, so the evaluation can't
  # judge them.
  SEARCH_KEYS = {
    category_training: %i[exclude_transfers skip_self_labels],
    words: %i[include_notes spread_filter word_split
              drop_numbers keep_single_chars drop_codes binary bigrams],
    merchant: %i[merchant_name_words merchant_field],
    amount: %i[amount_field amount_by_direction],
    account: %i[account_field],
    scoring: %i[complement smoothing separate_fields prior]
  }.freeze
  # Step 1 of search: each set tried in every on/off combination, in turn,
  # and then fixed: the fields; whether the merchant and account score apart
  # from the words; what's read as words.
  FEATURE_SETS = [
    %i[merchant_field amount_field account_field],
    %i[separate_fields],
    %i[merchant_name_words include_notes]
  ].freeze
  # The values tried for a choice or a number, its default among them.
  SEARCH_STEPS = {
    word_split: Family::BayesSettings::CHOICES[:word_split],
    smoothing: [ 0.03, 0.1, 0.3, 1.0 ]
  }.freeze
  # A setting that does nothing unless this holds isn't tried.
  SEARCH_ONLY_IF = {
    amount_by_direction: :amount_field.to_proc,
    separate_fields: ->(settings) { settings.merchant_field || settings.account_field }
  }.freeze

  # The latest result; when its "digest" differs from the current settings'
  # the page says they've changed since.
  def self.cached(family)
    result = Rails.cache.read(cache_key(family))
    result if result&.dig("version") == RESULT_VERSION
  end

  def self.running?(family)
    Rails.cache.read(running_key(family)).present?
  end

  def self.mark_running!(family)
    Rails.cache.write(running_key(family), true, expires_in: RUNNING_TTL)
  end

  # Marks a run as started unless one already is; false if one is.
  def self.start_running!(family)
    Rails.cache.write(running_key(family), true, expires_in: RUNNING_TTL, unless_exist: true)
  end

  # The chosen cost of a mistake, kept across runs and reloads.
  def self.weight(family)
    Rails.cache.read(weight_key(family)) || DEFAULT_WEIGHT
  end

  def self.remember_weight!(family, weight)
    Rails.cache.write(weight_key(family), weight.to_i.clamp(WEIGHTS), expires_in: CACHE_TTL)
  end

  def self.weight_key(family)
    [ "bayes-evaluation-weight", family.id ]
  end

  # The matcher's best cell for weight, over every cutoff: [cutoff, number
  # agreeing, similarity] where right − weight × wrong is highest; on a tie,
  # the most agreeing, then the highest similarity, then the highest cutoff
  # (the fewest words ignored). nil without a matcher result, or when it
  # scored no transactions. The page shows the table at its cutoff.
  def self.best_matcher(result, weight)
    return if result.dig("matcher", "n")&.zero?

    cells = result.dig("matcher", "cutoffs").to_h.flat_map do |cutoff, sweeps|
      sweeps.flat_map { |agreeing, sweep| sweep.map { |row| [ cutoff, agreeing, row ] } }
    end
    cutoff, agreeing, row = cells.max_by { |cutoff, agreeing, row| [ row["right"] - weight * row["wrong"], agreeing, row["threshold"], cutoff ] }
    [ cutoff, agreeing, row["threshold"] ] if row
  end

  # The merchant matcher table's columns, like the category one's: yours,
  # the best found for weight (only after Find best settings, as for the
  # categories) and the defaults, each a cutoff and number agreeing;
  # [[column, cutoff, agreeing, sweep (empty if it wasn't scored, e.g. a
  # cutoff typed in)]]. nil without a matcher result.
  def self.matcher_columns(result, settings, weight)
    best_cutoff, best_agreeing, = best_matcher(result, weight)
    return unless best_cutoff

    defaults = Family::BayesSettings::DEFAULTS
    columns = [ [ "current", settings.similar_common_share, settings.similar_min_neighbours ] ]
    columns << [ "best", best_cutoff, best_agreeing ] if result["best"]
    columns << [ "defaults", defaults[:similar_common_share], defaults[:similar_min_neighbours] ]
    columns.map { |column, cutoff, agreeing| [ column, cutoff, agreeing, result.dig("matcher", "cutoffs", cutoff, agreeing) || [] ] }
  end

  # The matcher column whose mistakes the page lists, for the button
  # pressed last, as for the categories (mistakes), at its own similarity
  # (Best found's best one): [column, similarity, sweep row]. nil without a
  # matcher result, or when that similarity or cutoff wasn't scored.
  def self.matcher_mistakes(result, settings, weight)
    column = { "find_best" => "best", "reset" => "defaults" }.fetch(result["action"], "current")
    _, cutoff, _, sweep = matcher_columns(result, settings, weight)&.find { |name, *| name == column }
    return unless cutoff

    similarity = case column
    when "best" then best_matcher(result, weight).last
    when "defaults" then Family::BayesSettings::DEFAULTS[:similar_threshold]
    else settings.similar_threshold
    end
    row = sweep.find { |r| r["threshold"] == similarity }
    [ column, similarity, row ] if row
  end

  # Everything Apply saves: best_changes and matcher_changes; {} before
  # Find best settings. Too little history holds back only the categories':
  # the matcher is scored on the months shown, never searched.
  def self.apply_changes(result, settings, weight)
    return {} unless result["best"]

    (result["short_history"] ? {} : best_changes(result, weight)).merge(matcher_changes(result, settings, weight))
  end

  # What Apply saves for the matcher: the best cell's cutoff, number
  # agreeing and similarity, where they differ from settings.
  def self.matcher_changes(result, settings, weight)
    cutoff, agreeing, similarity = best_matcher(result, weight)
    return {} unless cutoff

    { "similar_common_share" => cutoff, "similar_min_neighbours" => agreeing, "similar_threshold" => similarity }
      .reject { |key, value| settings.public_send(key) == value }
  end

  # The threshold scoring most right − weight × wrong in a sweep, the
  # highest on a tie.
  def self.best_threshold(sweep, weight)
    sweep.max_by { |row| [ row["right"] - weight * row["wrong"], row["threshold"] ] }["threshold"]
  end

  # What Apply saves: the best found's changes, and the threshold scoring
  # best for weight on the months shown. Only the threshold is fitted to
  # them; the settings were searched without them.
  def self.best_changes(result, weight)
    best = result["best"]
    threshold = best_threshold(best.dig("report", "sweep"), weight)
    threshold == result.dig("current", "threshold") ? best["changes"] : best["changes"].merge("threshold" => threshold)
  end

  # The column whose mistakes the page lists, for the button pressed last,
  # and the threshold they're at: [column, report, threshold].
  def self.mistakes(result, weight)
    case result["action"]
    when "find_best" then [ "best", result.dig("best", "report"), best_changes(result, weight).fetch("threshold", result.dig("current", "threshold")) ]
    when "reset" then [ "defaults", result["defaults"], result.dig("defaults", "threshold") ]
    else [ "current", result["current"], result.dig("current", "threshold") ]
    end
  end

  def self.cache_key(family)
    [ "bayes-evaluation", family.id ]
  end

  def self.running_key(family)
    [ "bayes-evaluation-running", family.id ]
  end

  def initialize(family, settings: family.bayes_settings_object, today: Date.current, months: MONTHS)
    @family = family
    @settings = settings
    @today = today
    @months = months
  end

  # Runs, caches and returns the result (plain hashes, so it caches as is):
  # these settings and the defaults scored on the newest HOLDOUT_MONTHS, and
  # for find_best, "best": the search over the months before, scored there
  # too. The block sees each change it tries.
  def run!(action: "test", &progress)
    holdout = self.class.new(family, settings: settings, today: today, months: HOLDOUT_MONTHS)
    current = holdout.report
    defaults = Family::BayesSettings.new(excluded_category_ids: settings.excluded_category_ids)
    result = {
      "version" => RESULT_VERSION,
      "action" => action,
      "digest" => settings.digest,
      "ran_at" => Time.current.iso8601,
      "months" => holdout.month_labels,
      "current" => current,
      "defaults" => defaults.digest == settings.digest ? current : holdout.report(defaults),
      "matcher" => holdout.matcher_report,
      # Too little to tune the categories on (apply_changes).
      "short_history" => current["n"].zero?
    }
    if action == "find_best"
      tuning = self.class.new(family, settings: settings, today: today << HOLDOUT_MONTHS, months: months - HOLDOUT_MONTHS)
      best, = tuning.search(&progress)
      result["best"] = {
        "changes" => best.values.reject { |key, value| settings.values[key] == value }.transform_keys(&:to_s),
        "report" => best.digest == settings.digest ? current : holdout.report(best)
      }
      # The search keeps a change only when it's better in all but one month
      # (better), so with fewer months it can test it can't keep any.
      result["short_history"] ||= tuning.months_with_history < months - HOLDOUT_MONTHS - 1
    end
    Rails.cache.write(self.class.cache_key(family), result, expires_in: CACHE_TTL)
    result
  ensure
    Rails.cache.delete(self.class.running_key(family))
  end

  # The page section whose strings label key.
  def self.section_for(key)
    key = key.to_sym
    return :matcher if key == :similar_threshold
    return :matcher_tuning if MATCHER_KEYS.include?(key)

    SEARCH_KEYS.find { |_, keys| keys.include?(key) }&.first || :classifier
  end

  # How a value reads on the page: on/off, a choice's label, or the number.
  def self.value_label(key, value)
    case value
    when true, false then I18n.t("settings.classifiers.evaluation.#{value ? "on" : "off"}")
    when String then I18n.t("settings.classifiers.#{section_for(key)}.#{key}_#{value}")
    else value
    end
  end

  def month_labels
    month_starts.map { |start| start.strftime("%Y-%m") }
  end

  # One settings' scores, uncached (bin/rails runner scripts compare many):
  # { "n", "threshold", "auc", "month_aucs" => [auc of each month alone],
  #   "sweep" => [{ "threshold", "right", "wrong" }],
  #   "confusions" => { threshold => [[actual, predicted, count]] },
  #   "uncategorized" => { threshold => [[actual, count]] }: left unanswered }
  def report(settings = self.settings)
    by_month = month_starts.map { |start| month_results(settings, start) }
    results = by_month.flatten(1)
    sweep = (THRESHOLDS | [ settings.threshold ]).sort.map do |threshold|
      answered = results.select { |confidence, _, _, _| confidence && confidence >= threshold }
      right = answered.count { |_, correct, _, _| correct }
      { "threshold" => threshold, "right" => right, "wrong" => answered.size - right }
    end
    confusions = sweep.to_h do |row|
      mistakes = results.select { |confidence, correct, _, _| confidence && confidence >= row["threshold"] && !correct }
                        .group_by { |_, _, actual, predicted| [ actual, predicted ] }
                        .map { |(actual, predicted), rows| [ category_names[actual], category_names[predicted], rows.size ] }
                        .sort_by { |_, _, count| -count }
                        .first(TOP_CONFUSIONS)
      [ row["threshold"], mistakes ]
    end
    uncategorized = sweep.to_h do |row|
      left = results.reject { |confidence, _, _, _| confidence && confidence >= row["threshold"] }
                    .group_by { |_, _, actual, _| actual }
                    .map { |actual, rows| [ category_names[actual], rows.size ] }
                    .sort_by { |_, count| -count }
                    .first(TOP_CONFUSIONS)
      [ row["threshold"], left ]
    end
    auc = ->(rows) { self.class.roc_auc(rows.map { |_, _, actual, _, probabilities| [ actual, probabilities ] })&.round(4) }
    { "n" => results.size, "threshold" => settings.threshold, "auc" => auc.call(results), "month_aucs" => by_month.map(&auc),
      "sweep" => sweep, "confusions" => confusions, "uncategorized" => uncategorized }
  end

  # The matcher on these months: each month's transactions with a merchant
  # it could copy from, the merchant hidden and matched against the history
  # before the month; { "n", "cutoffs" => { cutoff => { agreeing =>
  # [{ "threshold" (the similarity), "right", "wrong", "confusions" =>
  # [[actual, copied, count]], "unfilled" => [[actual, count]] }] } } }, at
  # each cutoff, similarity and agreeing it offers, by merchant name. Right
  # is the merchant they have.
  def matcher_report
    thresholds = Family::BayesSettings::STEPS[:similar_threshold]
    cutoffs = Family::BayesSettings::STEPS[:similar_common_share]
    # Each month's pool and test transactions, loaded once for every cutoff.
    months = month_starts.map do |start|
      filler = Family::SimilarMerchantFiller.new(family, settings: settings, as_of: start - 1.day)
      [ filler.pool, filler.confirmed.where(entries: { date: start...(start >> 1) }).preload(:entry).to_a ]
    end
    names = Merchant.where(id: months.flat_map { |pool, tested| (pool + tested).map(&:merchant_id) }.uniq).pluck(:id, :name).to_h
    by_cutoff = cutoffs.index_with do |cutoff|
      rows = months.flat_map do |pool, tested|
        matcher = Family::SimilarMatcher.new(pool, threshold: thresholds.min, min_neighbours: 1, common_share: cutoff)
        tested.map { |transaction| [ matcher.neighbours(transaction).map { |neighbour, similarity| [ neighbour.merchant_id, similarity ] }, transaction.merchant_id ] }
      end
      matcher_sweeps(rows, thresholds, names)
    end
    { "n" => months.sum { |_, tested| tested.size }, "cutoffs" => by_cutoff }
  end

  # One-vs-rest ROC-AUC over [[actual category id, { category id => score }]],
  # each category weighted by how many rows are in it (its own AUC is noisy
  # when it has only a few); a missing score is 0, ties count half. nil when
  # no category has rows both in and out of it. Needs no threshold: it asks
  # how well the scores rank each category's rows above the rest.
  def self.roc_auc(rows)
    aucs = rows.map(&:first).tally.filter_map do |category_id, positives|
      negatives = rows.size - positives
      next if negatives.zero?

      scores = rows.map { |actual, scores| [ scores.fetch(category_id, 0.0), actual == category_id ] }.sort_by(&:first)
      rank_sum = 0.0
      scores.chunk_while { |a, b| a.first == b.first }.inject(0) do |before, tied|
        rank_sum += tied.count(&:last) * (before + (tied.size + 1) / 2.0)
        before + tied.size
      end
      [ (rank_sum - positives * (positives + 1) / 2.0) / (positives * negatives), positives ]
    end
    return nil if aucs.empty?

    aucs.sum { |auc, weight| auc * weight } / aucs.sum(&:last)
  end

  # [settings, report]: the best settings, starting from these, in two
  # steps, each fixing what it picks, by ROC-AUC, which needs no threshold;
  # a change is kept only when it's higher over all the months and in all
  # but one of them alone, so a gain in a month or two that's just noise
  # isn't taken. The threshold is picked afterwards (best_threshold), for
  # the chosen cost of a mistake.
  # 1. Features: each of FEATURE_SETS in every combination.
  # 2. Parameters, greedily: try flipping each on/off setting and each other
  #    step of a number, keep the best change while it raises the AUC,
  #    repeat. First everything else, then Scoring.
  # The block sees each change tried, as { key => value }.
  def search(&progress)
    best, best_report = settings, report(settings)
    FEATURE_SETS.each { |keys| best, best_report = every_combination(best, best_report, keys, &progress) }
    features = FEATURE_SETS.flatten
    best, best_report = greedy(best, best_report, SEARCH_KEYS.except(:scoring).values.flatten - features, &progress)
    greedy(best, best_report, SEARCH_KEYS[:scoring] - features, &progress)
  end

  # How many of these months have transactions to test and history before
  # them to train on.
  def months_with_history
    month_starts.count do |start|
      tested_scope.where(entries: { date: start...(start >> 1) }).exists? && tested_scope.where(entries: { date: ...start }).exists?
    end
  end

  private
    attr_reader :family, :settings, :today, :months

    # { agreeing => [{ "threshold", "right", "wrong", "confusions",
    # "unfilled" }] } for rows of [[[merchant id, similarity] of each
    # neighbour], actual merchant id]; names: { merchant id => name }.
    def matcher_sweeps(rows, thresholds, names)
      Family::BayesSettings::STEPS[:similar_min_neighbours].index_with do |min|
        thresholds.map do |threshold|
          # [actual, copied], copied nil where it doesn't copy.
          answers = rows.map do |neighbours, actual|
            [ actual, Family::SimilarMatcher.agreed(neighbours.filter_map { |merchant_id, similarity| merchant_id if similarity >= threshold }, min) ]
          end
          wrong = answers.select { |actual, copied| copied && copied != actual }
          top = ->(pairs) { pairs.tally.sort_by { |_, count| -count }.first(TOP_CONFUSIONS) }
          { "threshold" => threshold, "right" => answers.count { |actual, copied| copied == actual }, "wrong" => wrong.size,
            "confusions" => top.call(wrong).map { |(actual, copied), count| [ names[actual], names[copied], count ] },
            "unfilled" => top.call(answers.filter_map { |actual, copied| actual unless copied }).map { |actual, count| [ names[actual], count ] } }
        end
      end
    end

    # [settings, report] with the on/off keys (those that do something) set
    # to their best combination; on a tie, the fewest changes from best.
    def every_combination(best, best_report, keys, &progress)
      keys = searchable(best, keys)
      start = best
      combinations = [ true, false ].repeated_permutation(keys.size).map do |values|
        keys.zip(values).to_h.reject { |key, value| start.public_send(key) == value }
      end
      combinations.reject(&:empty?).sort_by.with_index { |changes, i| [ changes.size, i ] }.each do |changes|
        best, best_report = better(best, best_report, start.merge(changes), changes, &progress)
      end
      [ best, best_report ]
    end

    # [settings, report] after greedily changing keys, starting from best.
    def greedy(best, best_report, keys, &progress)
      loop do
        changes = searchable(best, keys).flat_map do |key|
          current_value = best.public_send(key)
          (SEARCH_STEPS.fetch(key) { [ !current_value ] } - [ current_value ]).map { |value| { key => value } }
        end
        top, top_report = best, best_report
        changes.each do |change|
          top, top_report = better(top, top_report, best.merge(change), change, &progress)
        end
        return [ best, best_report ] if top.equal?(best)

        best, best_report = top, top_report
      end
    end

    def searchable(settings, keys)
      keys.select { |key| SEARCH_ONLY_IF.fetch(key, ->(_) { true }).call(settings) }
    end

    # [settings, report]: candidate's when its ROC-AUC is higher over all the
    # months and in all but one of them alone, else best's. Yields changes
    # first, as it's tried.
    def better(best, best_report, candidate, changes)
      yield changes if block_given?
      candidate_report = report(candidate)
      auc = ->(value) { value || -Float::INFINITY }
      months_better = candidate_report["month_aucs"].zip(best_report["month_aucs"]).count { |mine, theirs| auc.call(mine) > auc.call(theirs) }
      if auc.call(candidate_report["auc"]) > auc.call(best_report["auc"]) && months_better >= months - 1
        [ candidate, candidate_report ]
      else
        [ best, best_report ]
      end
    end

    def month_starts
      first = today.beginning_of_month
      (1..months).map { |i| first << i }.reverse
    end

    # [[confidence or nil, correct?, actual category id, predicted id,
    # { category id => score }]] for one month, at no threshold so the sweep
    # can filter. Where it doesn't answer, every category scores alike for
    # the AUC: no information, rather than a row left out.
    def month_results(settings, start)
      categorizer = Family::BayesCategorizer.new(family, settings: settings, as_of: start - 1.day)
      uniform = categorizer.category_ids.index_with { 1.0 / categorizer.category_ids.size }
      test_transactions(categorizer, start).map do |transaction|
        probabilities = categorizer.probabilities(transaction)
        category_id, confidence = probabilities.max_by { |_, probability| probability }
        [ confidence, category_id == transaction.category_id, transaction.category_id, category_id, probabilities.presence || uniform ]
      end
    end

    def test_transactions(categorizer, start)
      scope = tested_scope.where(entries: { date: start...(start >> 1) })
      excluded = categorizer.excluded_category_ids
      scope = scope.where.not(category_id: excluded) if excluded.any?
      scope.preload(:entry, :merchant).to_a
    end

    # Categorized transactions whose category isn't an automatic guess.
    def tested_scope
      family.transactions.where.not(category_id: nil).where.not(Transaction.category_from_sql("ai", "bayes")).joins(:entry)
    end

    def category_names
      @category_names ||= family.categories.pluck(:id, :name).to_h
    end
end
