# Reports the categorization cascade as it actually runs in production:
# Family::BayesCategorizer first, then a paid provider on whatever Bayes
# declined.
#
# The reason this exists rather than a three-column accuracy table: a flat table
# credits every provider for the easy rows Bayes would have absorbed for free,
# so it measures work the provider never performs. The number that decides
# whether a provider is worth paying for is its accuracy on the residual — the
# tail Bayes could not classify, which is systematically harder than the dataset
# average.
#
# Both legs must have been run over the same test split (same seed and ratio),
# or the residual is not the residual. Mismatches are reported rather than
# silently papered over.
class Eval::Reporters::CascadeReport
  def initialize(bayes_run:, provider_runs:)
    @bayes_run = bayes_run
    @provider_runs = Array(provider_runs)
  end

  def to_s
    lines = []
    lines << "=" * 78
    lines << "Categorization cascade — #{bayes_run.dataset.name}"
    lines << "=" * 78
    lines << split_description
    lines << ""
    lines.concat(split_mismatch_warnings)
    lines << stage_one
    lines << ""
    lines << stage_two
    lines << ""
    lines << cascade_totals
    lines << ""
    lines << (degenerate_bayes? ? DEGENERATE_WARNING : LIMITATION)
    lines.join("\n")
  end

  # Zero coverage means the dataset could not train the model, not that the
  # model declined to classify. Callers use this to avoid quoting the number.
  def degenerate_bayes?
    bayes_results.any? && bayes_covered.empty?
  end

  def summary
    {
      bayes: {
        covered: bayes_covered.size,
        declined: bayes_declined_sample_ids.size,
        test_size: bayes_results.size,
        coverage: percentage(bayes_covered.size, bayes_results.size),
        accuracy_on_covered: percentage(bayes_correct.size, bayes_covered.size)
      },
      providers: provider_runs.to_h { |run| [ label_for(run), provider_summary(run) ] }
    }
  end

  private
    attr_reader :bayes_run, :provider_runs

    # Coverage of zero is not a result. It means the dataset could not train the
    # model at all, and a reader must not carry away "Bayes classified nothing"
    # as a finding about Bayes.
    DEGENERATE_WARNING = <<~TEXT.strip
      THIS RUN DOES NOT MEASURE BAYES. Coverage is zero, which on a golden
      dataset means the model had nothing to generalize from rather than that it
      failed. These datasets carry roughly one transaction per distinct merchant,
      so a held-out sample shares almost no vocabulary with training, and what it
      does share is generic (state codes, digits) rather than merchant identity.
      Measured on categorization_golden_v2: the highest confidence any held-out
      sample reached was 0.217 against a 0.70 gate, with a median of 0.087, and
      a uniform guess across 23 categories is 0.043. There is no signal to
      threshold.

      Consequently the residual below is the entire test set, so the provider
      columns are identical and the cascade cannot be assessed from this data.
      Evaluating Bayes needs a dataset with realistic repetition — the same
      merchants recurring, as a real family's history does. Until then, treat
      the Stage 1 row as "not measured", not as zero.
    TEXT

    LIMITATION = <<~TEXT.strip
      Caveat on the Bayes leg: a golden dataset is roughly one transaction per
      distinct merchant, while a real family's history is the same few merchants
      repeating. Naive Bayes depends on that repetition and has almost none here,
      so its coverage below is close to a worst case and very likely understates
      production. The provider-on-residual figures inherit that: if Bayes really
      covers more in production, the residual is harder still than shown here.
    TEXT

    def split_description
      describe = bayes_run.provider_config.slice("split_role", "split_seed", "split_ratio")
      counts = bayes_results.size
      nulls = bayes_results.count(&:null_expected)
      "Split: #{describe.to_json} — test set #{counts} samples (#{nulls} null-expected)"
    end

    def split_mismatch_warnings
      keys = %w[split_seed split_ratio split_role]
      expected = bayes_run.provider_config.slice(*keys)

      provider_runs.filter_map do |run|
        actual = run.provider_config.slice(*keys)
        next if actual == expected

        "WARNING: #{label_for(run)} ran on a different split (#{actual.to_json}); " \
          "its residual figures are not comparable.\n"
      end
    end

    def stage_one
      covered = bayes_covered.size
      total = bayes_results.size
      correct = bayes_correct.size

      [
        "STAGE 1 — naive Bayes (local, no API cost)",
        format("  covered              %4d / %-4d  (%s of test set)", covered, total, percentage_s(covered, total)),
        format("  accuracy on covered  %s", percentage_s(correct, covered)),
        format("  resolved correctly   %4d / %-4d  (%s of test set)", correct, total, percentage_s(correct, total))
      ].join("\n")
    end

    def stage_two
      residual = bayes_declined_sample_ids
      rows = provider_runs.map do |run|
        s = provider_summary(run)
        format(
          "  %-26s %-12s %-14s %s",
          label_for(run),
          percentage_s(s[:residual_correct], s[:residual_scored]),
          percentage_s(s[:full_correct], s[:full_scored]),
          s[:residual_scored] == residual.size ? "" : "(only #{s[:residual_scored]}/#{residual.size} of residual scored)"
        ).rstrip
      end

      [
        "STAGE 2 — on the #{residual.size} samples Bayes declined",
        format("  %-26s %-12s %-14s", "provider", "on residual", "on full test"),
        format("  %-26s %-12s %-14s", "-" * 26, "-" * 12, "-" * 14),
        *rows,
        "",
        "  The gap between those two columns is what a full-dataset benchmark",
        "  overstates: the left column is the work the provider actually receives."
      ].join("\n")
    end

    def cascade_totals
      total = bayes_results.size
      rows = provider_runs.map do |run|
        s = provider_summary(run)
        combined = bayes_correct.size + s[:residual_correct]
        format("  bayes + %-20s %4d / %-4d  (%s)", label_for(run), combined, total, percentage_s(combined, total))
      end

      [ "CASCADE TOTAL — share of the test set resolved correctly end to end", *rows ].join("\n")
    end

    def provider_summary(run)
      results = run.results.includes(:sample).to_a
      residual = results.select { |result| bayes_declined_sample_ids.include?(result.eval_sample_id) }

      {
        residual_scored: residual.size,
        residual_correct: residual.count(&:correct),
        residual_accuracy: percentage(residual.count(&:correct), residual.size),
        full_scored: results.size,
        full_correct: results.count(&:correct),
        full_accuracy: percentage(results.count(&:correct), results.size)
      }
    end

    def bayes_results
      @bayes_results ||= bayes_run.results.includes(:sample).to_a
    end

    def bayes_covered
      @bayes_covered ||= bayes_results.reject { |result| declined?(result) }
    end

    def bayes_correct
      @bayes_correct ||= bayes_covered.select(&:correct)
    end

    def bayes_declined_sample_ids
      @bayes_declined_sample_ids ||= bayes_results.select { |result| declined?(result) }.map(&:eval_sample_id).to_set
    end

    def declined?(result)
      result.metadata["declined"] == true
    end

    def label_for(run)
      "#{run.provider}:#{run.model}"
    end

    def percentage(numerator, denominator)
      return nil if denominator.to_i.zero?

      (numerator.to_f / denominator * 100).round(1)
    end

    def percentage_s(numerator, denominator)
      value = percentage(numerator, denominator)
      value.nil? ? "n/a" : "#{value}%"
    end
end
