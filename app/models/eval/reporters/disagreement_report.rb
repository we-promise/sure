# Where two providers actually differ, sample by sample.
#
# Two accuracy percentages can be identical and still describe completely
# different behaviour: 96% and 95% might be near-identical answers, or might be
# two providers failing on disjoint halves of the dataset. Only a paired
# comparison tells them apart, and it is the paired view that says whether one
# provider is a safe replacement for the other or merely equally good on
# average.
#
# Pairs on sample, so both runs must cover the same dataset.
class Eval::Reporters::DisagreementReport
  MAX_EXAMPLES = 5

  attr_reader :baseline, :candidate

  def initialize(baseline, candidate)
    @baseline = baseline
    @candidate = candidate
  end

  def comparable?
    baseline.eval_dataset_id == candidate.eval_dataset_id && paired.any?
  end

  def paired_count
    paired.size
  end

  # Candidate right where the baseline was wrong — the cases that argue for it.
  def candidate_wins
    @candidate_wins ||= paired.select { |base, cand| cand.correct && !base.correct }
  end

  # Baseline right where the candidate was wrong — the regressions a switch buys.
  def candidate_losses
    @candidate_losses ||= paired.select { |base, cand| base.correct && !cand.correct }
  end

  def both_correct
    @both_correct ||= paired.select { |base, cand| base.correct && cand.correct }
  end

  def both_wrong
    @both_wrong ||= paired.reject { |base, cand| base.correct || cand.correct }
  end

  # Both wrong with the same answer usually indicts the dataset, not the
  # providers — worth separating before anyone "fixes" a model.
  def both_wrong_same_answer
    both_wrong.select { |base, cand| base.actual_output == cand.actual_output }
  end

  def both_wrong_different_answers
    both_wrong.reject { |base, cand| base.actual_output == cand.actual_output }
  end

  # How often they produced the identical answer, right or wrong. High agreement
  # with a small accuracy gap means the providers are near-interchangeable.
  def agreement_rate
    return nil if paired.empty?

    same = paired.count { |base, cand| base.actual_output == cand.actual_output }
    (same.to_f / paired.size * 100).round(2)
  end

  def to_h
    return { comparable: false } unless comparable?

    {
      comparable: true,
      baseline: run_label(baseline),
      candidate: run_label(candidate),
      paired_samples: paired_count,
      agreement_rate: agreement_rate,
      both_correct: both_correct.size,
      candidate_wins: candidate_wins.size,
      candidate_losses: candidate_losses.size,
      both_wrong_same_answer: both_wrong_same_answer.size,
      both_wrong_different_answers: both_wrong_different_answers.size,
      examples: {
        wins: examples(candidate_wins),
        losses: examples(candidate_losses)
      }
    }
  end

  def to_table
    unless comparable?
      return "Runs are not comparable — they must cover the same dataset and share samples."
    end

    lines = []
    lines << "#{run_label(candidate)} vs #{run_label(baseline)} over #{paired_count} paired samples"
    lines << ""
    lines << format("  %-32s %5d", "Both correct", both_correct.size)
    lines << format("  %-32s %5d", "#{run_label(candidate)} wins", candidate_wins.size)
    lines << format("  %-32s %5d", "#{run_label(candidate)} loses", candidate_losses.size)
    lines << format("  %-32s %5d", "Both wrong (same answer)", both_wrong_same_answer.size)
    lines << format("  %-32s %5d", "Both wrong (different answers)", both_wrong_different_answers.size)
    lines << ""
    lines << "  Agreement rate: #{agreement_rate}%"

    if candidate_losses.any?
      lines << ""
      lines << "  Regressions a switch would buy:"
      examples(candidate_losses).each do |example|
        lines << "    #{example[:sample]}"
        lines << "      expected #{example[:expected].inspect}, got #{example[:candidate].inspect}"
      end
    end

    lines.join("\n")
  end

  private
    def paired
      @paired ||= begin
        base_by_sample = baseline.results.includes(:sample).index_by(&:eval_sample_id)
        cand_by_sample = candidate.results.includes(:sample).index_by(&:eval_sample_id)

        (base_by_sample.keys & cand_by_sample.keys).map do |sample_id|
          [ base_by_sample[sample_id], cand_by_sample[sample_id] ]
        end
      end
    end

    def examples(pairs)
      pairs.first(MAX_EXAMPLES).map do |base, cand|
        {
          sample: sample_label(cand.sample),
          expected: cand.sample.expected_output,
          baseline: base.actual_output,
          candidate: cand.actual_output
        }
      end
    end

    # Datasets differ by eval type, so fall back through the likely description
    # fields rather than assuming a categorization shape.
    def sample_label(sample)
      input = sample.input_data || {}
      input["description"].presence || input["name"].presence || input["prompt"].presence || "sample #{sample.id}"
    end

    def run_label(run)
      "#{run.provider}:#{run.model}"
    end
end
