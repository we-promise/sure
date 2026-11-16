# Turns a paired comparison into replace / shadow / skip, with the reasoning
# stated rather than implied.
#
# The bar for "replace" is deliberately high. Two providers scoring 96% and 95%
# on 200 samples differ by two samples, which is noise — a report that called
# that a win would be actively misleading. Significance is tested with McNemar's
# test because the comparison is paired: both providers answered the same
# samples, so what matters is the count of samples where they disagreed, not the
# difference of two independent proportions.
#
# Default verdict is "shadow": run it alongside, gather production evidence,
# decide later.
class Eval::Reporters::Recommendation
  # Replace demands strong evidence; a tie is judged at the conventional 0.05.
  REPLACE_SIGNIFICANCE = 0.01
  TIE_SIGNIFICANCE = 0.05

  # Below this, a paired test cannot say much either way.
  MIN_SAMPLES_FOR_VERDICT = 50
  MIN_SAMPLES_TO_REPLACE = 100

  # A speed or cost edge only counts if it is worth changing a provider over.
  MATERIAL_RATIO = 2.0

  attr_reader :baseline, :candidate, :disagreement, :calibration

  def initialize(baseline:, candidate:, disagreement: nil, calibration: nil)
    @baseline = baseline
    @candidate = candidate
    @disagreement = disagreement || Eval::Reporters::DisagreementReport.new(baseline, candidate)
    @calibration = calibration || Eval::Metrics::Calibration.new(candidate)
  end

  def verdict
    to_h[:verdict]
  end

  def to_h
    return skip("runs are not comparable — different datasets or no shared samples") unless disagreement.comparable?
    return skip(broken_reason) if broken?
    return shadow("only #{disagreement.paired_count} paired samples; too few to judge") if too_few_samples?

    if significantly_worse?
      skip(accuracy_sentence("worse"))
    elsif significantly_better?
      replace_or_shadow
    else
      tie
    end
  end

  def to_table
    result = to_h
    lines = [ "Recommendation: #{result[:verdict].upcase}" ]
    lines << ""
    result[:reasons].each { |reason| lines << "  - #{reason}" }
    lines << ""
    lines << "  p = #{result[:p_value]} (McNemar, #{disagreement.candidate_wins.size} wins vs #{disagreement.candidate_losses.size} losses)" if result[:p_value]
    lines.join("\n")
  end

  # Two-sided McNemar with continuity correction. Only the discordant pairs
  # carry information: samples both providers got right, or both got wrong, say
  # nothing about which is better.
  def p_value
    @p_value ||= begin
      wins = disagreement.candidate_wins.size
      losses = disagreement.candidate_losses.size
      discordant = wins + losses

      if discordant.zero?
        1.0
      else
        chi_square = (((wins - losses).abs - 1)**2) / discordant.to_f
        # Exact survival function for chi-square with one degree of freedom.
        Math.erfc(Math.sqrt(chi_square / 2.0)).round(4)
      end
    end
  end

  private
    def broken?
      candidate_errors.positive? || candidate.status != "completed"
    end

    def broken_reason
      if candidate.status != "completed"
        "candidate run did not complete (status: #{candidate.status})"
      else
        "#{candidate_errors} of #{disagreement.paired_count} candidate requests errored; the run is not a valid measurement"
      end
    end

    def candidate_errors
      (candidate.metrics || {})["samples_errored"].to_i
    end

    def too_few_samples?
      disagreement.paired_count < MIN_SAMPLES_FOR_VERDICT
    end

    def significantly_better?
      p_value < TIE_SIGNIFICANCE && disagreement.candidate_wins.size > disagreement.candidate_losses.size
    end

    def significantly_worse?
      p_value < TIE_SIGNIFICANCE && disagreement.candidate_losses.size > disagreement.candidate_wins.size
    end

    def replace_or_shadow
      reasons = [ accuracy_sentence("better") ]
      reasons.concat(performance_reasons)
      reasons << calibration_sentence if calibration_sentence

      if p_value < REPLACE_SIGNIFICANCE && disagreement.paired_count >= MIN_SAMPLES_TO_REPLACE
        build(:replace, reasons + [ "evidence is strong enough to switch the default" ])
      else
        build(:shadow, reasons + [ "advantage is real but thin; run it alongside before switching" ])
      end
    end

    def tie
      reasons = [ accuracy_sentence("indistinguishable") ]
      perf = performance_reasons
      reasons.concat(perf)
      reasons << calibration_sentence if calibration_sentence

      if perf.any?
        build(:shadow, reasons + [ "no quality difference, but the throughput or cost edge may justify it in production" ])
      else
        build(:skip, reasons + [ "no measurable advantage on any axis" ])
      end
    end

    def accuracy_sentence(direction)
      wins = disagreement.candidate_wins.size
      losses = disagreement.candidate_losses.size

      case direction
      when "indistinguishable"
        "accuracy is statistically indistinguishable (#{wins} wins, #{losses} losses over " \
          "#{disagreement.paired_count} paired samples, p = #{p_value})"
      else
        "candidate is significantly #{direction} (#{wins} wins, #{losses} losses, p = #{p_value})"
      end
    end

    def performance_reasons
      reasons = []
      reasons << latency_sentence if latency_advantage&.>= MATERIAL_RATIO
      reasons << cost_sentence if cost_sentence
      reasons
    end

    def latency_advantage
      base = metric(baseline, "avg_latency_ms")
      cand = metric(candidate, "avg_latency_ms")
      return nil unless base&.positive? && cand&.positive?

      base / cand
    end

    def latency_sentence
      format("candidate is %.1fx faster per sample (%dms vs %dms)",
             latency_advantage,
             metric(candidate, "avg_latency_ms"),
             metric(baseline, "avg_latency_ms"))
    end

    # Cost is only comparable when both sides recorded it. The OpenAI path does
    # not populate eval_results.cost, so its total lands at zero — which must not
    # be read as "free".
    def cost_sentence
      if !cost_instrumented?(baseline) && cost_instrumented?(candidate)
        "cost comparison unavailable: only the candidate reports per-call cost " \
          "(#{format_cost(observed_cost(candidate))} total); the baseline records none"
      elsif cost_instrumented?(baseline) && cost_instrumented?(candidate)
        candidate_cost = observed_cost(candidate)
        return nil unless candidate_cost.positive?

        ratio = observed_cost(baseline) / candidate_cost
        return nil unless ratio >= MATERIAL_RATIO

        format("candidate costs %.1fx less (%s vs %s)", ratio,
               format_cost(candidate_cost), format_cost(observed_cost(baseline)))
      end
    end

    # Summed from the results rather than read off Eval::Run#total_cost: that
    # column is denormalized at completion and sits at zero for a run whose
    # provider reports no cost, which is indistinguishable from genuinely free.
    def observed_cost(run)
      run.results.sum(:cost).to_f
    end

    def cost_instrumented?(run)
      run.results.where.not(cost: nil).exists?
    end

    def calibration_sentence
      return nil unless calibration.supported?

      if calibration.overconfident?
        "candidate confidence is overconfident (calibration error " \
          "#{(calibration.expected_calibration_error * 100).round(1)} points) — " \
          "not safe to gate behaviour on yet"
      else
        "candidate reports usable confidence (calibration error " \
          "#{(calibration.expected_calibration_error * 100).round(1)} points)"
      end
    end

    def metric(run, key)
      (run.metrics || {})[key]&.to_f
    end

    def format_cost(value)
      "$#{value.to_f.round(6)}"
    end

    def skip(reason)
      build(:skip, [ reason ])
    end

    def shadow(reason)
      build(:shadow, [ reason ])
    end

    def build(verdict, reasons)
      {
        verdict: verdict.to_s,
        baseline: "#{baseline.provider}:#{baseline.model}",
        candidate: "#{candidate.provider}:#{candidate.model}",
        reasons: reasons,
        p_value: disagreement.comparable? ? p_value : nil
      }
    end
end
