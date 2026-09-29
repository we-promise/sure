# Compares a provider's stated confidence against how often it was actually
# right. A provider that says 0.9 should be right about nine times in ten; one
# that says 0.9 and is right six times in ten has confidence that cannot be
# used to gate anything.
#
# This is reported separately from accuracy because it answers a different
# question. Accuracy asks "how often is it right"; calibration asks "does it
# know when it is wrong" — which is what decides whether a confidence threshold
# can drive product behaviour, such as auto-applying a category versus queueing
# it for review.
#
# Providers that report no confidence at all (the next-token path) are not
# badly calibrated, they are unmeasurable. `supported?` distinguishes the two so
# a caller never reads an absent signal as a bad one.
class Eval::Metrics::Calibration
  BUCKET_COUNT = 10
  BUCKET_WIDTH = 1.0 / BUCKET_COUNT

  def initialize(eval_run)
    @eval_run = eval_run
  end

  def supported?
    scored.any?
  end

  def sample_count
    scored.size
  end

  # One entry per populated bucket: how confident the provider said it was, and
  # how often it was actually right at that confidence.
  def curve
    @curve ||= scored.group_by { |confidence, _correct| bucket_index(confidence) }.sort.map do |index, entries|
      count = entries.size
      mean_confidence = entries.sum { |confidence, _| confidence } / count
      accuracy = entries.count { |_, correct| correct }.to_f / count

      {
        range: bucket_label(index),
        count: count,
        mean_confidence: mean_confidence.round(4),
        accuracy: accuracy.round(4),
        # Negative means overconfident: it claimed more certainty than it earned.
        gap: (accuracy - mean_confidence).round(4)
      }
    end
  end

  # Weighted mean distance between stated confidence and observed accuracy.
  # 0.0 is perfect; 0.1 means the provider is out by ten points on average.
  def expected_calibration_error
    return nil unless supported?

    total = sample_count.to_f
    curve.sum { |bucket| (bucket[:count] / total) * bucket[:gap].abs }.round(4)
  end

  # Confidence that systematically overstates accuracy is the dangerous
  # direction: it is what would auto-apply a wrong category.
  def overconfident?
    return false unless supported?

    weighted_gap = curve.sum { |bucket| (bucket[:count] / sample_count.to_f) * bucket[:gap] }
    weighted_gap < -0.05
  end

  def to_h
    return { supported: false } unless supported?

    {
      supported: true,
      sample_count: sample_count,
      expected_calibration_error: expected_calibration_error,
      overconfident: overconfident?,
      buckets: curve
    }
  end

  def to_table
    return "No confidence reported — calibration cannot be measured for this provider." unless supported?

    lines = []
    lines << format("%-12s %7s %12s %10s %8s", "Confidence", "Samples", "Claimed", "Actual", "Gap")
    lines << "-" * 53

    curve.each do |bucket|
      lines << format(
        "%-12s %7d %11.1f%% %9.1f%% %+7.1f",
        bucket[:range],
        bucket[:count],
        bucket[:mean_confidence] * 100,
        bucket[:accuracy] * 100,
        bucket[:gap] * 100
      )
    end

    lines << "-" * 53
    lines << format("Expected calibration error: %.1f points%s",
                    expected_calibration_error * 100,
                    overconfident? ? " (overconfident)" : "")
    lines.join("\n")
  end

  private
    def scored
      @scored ||= @eval_run.results
                           .where("metadata->>'confidence' IS NOT NULL")
                           .pluck(Arel.sql("(metadata->>'confidence')::float"), :correct)
    end

    def bucket_index(confidence)
      return 0 if confidence.negative?

      [ (confidence / BUCKET_WIDTH).floor, BUCKET_COUNT - 1 ].min
    end

    def bucket_label(index)
      format("%.1f-%.1f", index * BUCKET_WIDTH, (index + 1) * BUCKET_WIDTH)
    end
end
