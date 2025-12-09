class Eval::Reporters::ComparisonReporter
  attr_reader :runs

  def initialize(runs)
    @runs = Array(runs).sort_by(&:model)
  end

  # Generate a text table for terminal display
  def to_table
    return "No runs to compare" if runs.empty?

    headers = build_headers
    rows = runs.map { |run| build_row(run) }

    # Calculate column widths
    all_rows = [ headers ] + rows
    widths = headers.each_index.map do |i|
      all_rows.map { |row| row[i].to_s.length }.max
    end

    # Build table
    separator = "+" + widths.map { |w| "-" * (w + 2) }.join("+") + "+"

    lines = []
    lines << separator
    lines << "| " + headers.each_with_index.map { |h, i| h.to_s.ljust(widths[i]) }.join(" | ") + " |"
    lines << separator

    rows.each do |row|
      lines << "| " + row.each_with_index.map { |c, i| c.to_s.ljust(widths[i]) }.join(" | ") + " |"
    end

    lines << separator
    lines.join("\n")
  end

  # Export to CSV file
  def to_csv(file_path)
    require "csv"

    CSV.open(file_path, "wb") do |csv|
      csv << csv_headers
      runs.each { |run| csv << csv_row(run) }
    end

    file_path
  end

  # Generate summary with best model recommendations
  def summary
    return {} if runs.empty?

    completed_runs = runs.select { |r| r.status == "completed" && r.metrics.present? }
    return {} if completed_runs.empty?

    best_accuracy = completed_runs.max_by { |r| r.metrics["accuracy"] || 0 }
    lowest_cost = completed_runs.min_by { |r| r.total_cost || Float::INFINITY }
    fastest = completed_runs.min_by { |r| r.metrics["avg_latency_ms"] || Float::INFINITY }

    {
      best_accuracy: {
        model: best_accuracy.model,
        value: best_accuracy.metrics["accuracy"],
        run_id: best_accuracy.id
      },
      lowest_cost: {
        model: lowest_cost.model,
        value: lowest_cost.total_cost&.to_f,
        run_id: lowest_cost.id
      },
      fastest: {
        model: fastest.model,
        value: fastest.metrics["avg_latency_ms"],
        run_id: fastest.id
      },
      recommendation: generate_recommendation(best_accuracy, lowest_cost, fastest)
    }
  end

  # Generate detailed comparison between runs
  def detailed_comparison
    return {} if runs.empty?

    {
      runs: runs.map(&:summary),
      comparison: pairwise_comparisons,
      summary: summary
    }
  end

  private

    def build_headers
      [ "Model", "Status", "Accuracy", "Precision", "Recall", "F1", "Latency (ms)", "Cost ($)", "Samples" ]
    end

    def build_row(run)
      metrics = run.metrics || {}

      [
        run.model,
        run.status,
        format_percentage(metrics["accuracy"]),
        format_percentage(metrics["precision"]),
        format_percentage(metrics["recall"]),
        format_percentage(metrics["f1_score"]),
        metrics["avg_latency_ms"]&.round(0) || "-",
        format_cost(run.total_cost),
        run.results.count
      ]
    end

    def csv_headers
      [
        "Run ID", "Model", "Provider", "Dataset", "Status",
        "Accuracy", "Precision", "Recall", "F1 Score",
        "Null Accuracy", "Hierarchical Accuracy",
        "Avg Latency (ms)", "Total Cost", "Cost Per Sample",
        "Samples Processed", "Samples Correct",
        "Duration (s)", "Run Date"
      ]
    end

    def csv_row(run)
      metrics = run.metrics || {}

      [
        run.id,
        run.model,
        run.provider,
        run.dataset.name,
        run.status,
        metrics["accuracy"],
        metrics["precision"],
        metrics["recall"],
        metrics["f1_score"],
        metrics["null_accuracy"],
        metrics["hierarchical_accuracy"],
        metrics["avg_latency_ms"],
        run.total_cost&.to_f,
        metrics["cost_per_sample"],
        metrics["samples_processed"],
        metrics["samples_correct"],
        run.duration_seconds,
        run.completed_at&.iso8601
      ]
    end

    def format_percentage(value)
      return "-" if value.nil?
      "#{value}%"
    end

    def format_cost(value)
      return "-" if value.nil?
      "$#{value.to_f.round(4)}"
    end

    def pairwise_comparisons
      return [] if runs.size < 2

      comparisons = []
      runs.combination(2).each do |run1, run2|
        comparisons << {
          models: [ run1.model, run2.model ],
          accuracy_diff: ((run1.metrics["accuracy"] || 0) - (run2.metrics["accuracy"] || 0)).round(2),
          cost_diff: ((run1.total_cost || 0) - (run2.total_cost || 0)).to_f.round(6),
          latency_diff: ((run1.metrics["avg_latency_ms"] || 0) - (run2.metrics["avg_latency_ms"] || 0)).round(0)
        }
      end
      comparisons
    end

    def generate_recommendation(best_accuracy, lowest_cost, fastest)
      parts = []

      # If one model wins all categories
      if best_accuracy.id == lowest_cost.id && lowest_cost.id == fastest.id
        return "#{best_accuracy.model} is the best choice overall (highest accuracy, lowest cost, fastest)."
      end

      # Accuracy recommendation
      if best_accuracy.metrics["accuracy"] && best_accuracy.metrics["accuracy"] >= 90
        parts << "For maximum accuracy, use #{best_accuracy.model} (#{best_accuracy.metrics['accuracy']}% accuracy)"
      end

      # Cost recommendation if significantly cheaper
      if lowest_cost.total_cost && lowest_cost.total_cost > 0
        cost_ratio = (best_accuracy.total_cost || 0) / lowest_cost.total_cost
        if cost_ratio > 1.5
          parts << "For cost efficiency, consider #{lowest_cost.model} (#{format_cost(lowest_cost.total_cost)} vs #{format_cost(best_accuracy.total_cost)})"
        end
      end

      # Speed recommendation
      if fastest.metrics["avg_latency_ms"] && fastest.id != best_accuracy.id
        latency_ratio = (best_accuracy.metrics["avg_latency_ms"] || 0) / (fastest.metrics["avg_latency_ms"] || 1)
        if latency_ratio > 1.5
          parts << "For speed, consider #{fastest.model} (#{fastest.metrics['avg_latency_ms']}ms vs #{best_accuracy.metrics['avg_latency_ms']}ms)"
        end
      end

      parts.empty? ? "All models perform similarly." : parts.join(". ")
    end
end
