namespace :evals do
  desc "List all evaluation datasets"
  task list_datasets: :environment do
    datasets = Eval::Dataset.order(:eval_type, :name)

    if datasets.empty?
      puts "No datasets found. Import a dataset with: rake evals:import_dataset[path/to/file.yml]"
      next
    end

    puts "=" * 80
    puts "Available Evaluation Datasets"
    puts "=" * 80
    puts

    datasets.group_by(&:eval_type).each do |eval_type, type_datasets|
      puts "#{eval_type.titleize}:"
      puts "-" * 40

      type_datasets.each do |dataset|
        status = dataset.active ? "active" : "inactive"
        puts "  #{dataset.name} (v#{dataset.version}) - #{dataset.sample_count} samples [#{status}]"
        puts "    #{dataset.description}" if dataset.description.present?
      end
      puts
    end
  end

  desc "Import dataset from YAML file"
  task :import_dataset, [ :file_path ] => :environment do |_t, args|
    file_path = args[:file_path] || ENV["FILE"]

    if file_path.blank?
      puts "Usage: rake evals:import_dataset[path/to/file.yml]"
      puts "   or: FILE=path/to/file.yml rake evals:import_dataset"
      exit 1
    end

    unless File.exist?(file_path)
      puts "Error: File not found: #{file_path}"
      exit 1
    end

    puts "Importing dataset from #{file_path}..."

    dataset = Eval::Dataset.import_from_yaml(file_path)

    puts "Successfully imported dataset:"
    puts "  Name: #{dataset.name}"
    puts "  Type: #{dataset.eval_type}"
    puts "  Version: #{dataset.version}"
    puts "  Samples: #{dataset.sample_count}"

    stats = dataset.statistics
    puts "  By difficulty: #{stats[:by_difficulty].map { |k, v| "#{k}=#{v}" }.join(', ')}"
  end

  desc "Run evaluation against a model"
  task :run, [ :dataset_name, :model ] => :environment do |_t, args|
    dataset_name = args[:dataset_name] || ENV["DATASET"]
    model = args[:model] || ENV["MODEL"] || "gpt-4.1"
    provider = ENV["PROVIDER"] || "openai"

    if dataset_name.blank?
      puts "Usage: rake evals:run[dataset_name,model]"
      puts "   or: DATASET=name MODEL=gpt-4 rake evals:run"
      exit 1
    end

    dataset = Eval::Dataset.find_by(name: dataset_name)

    if dataset.nil?
      puts "Error: Dataset '#{dataset_name}' not found"
      puts "Available datasets:"
      Eval::Dataset.pluck(:name).each { |n| puts "  - #{n}" }
      exit 1
    end

    run_name = "#{dataset_name}_#{model}_#{Time.current.strftime('%Y%m%d_%H%M%S')}"

    puts "=" * 80
    puts "Starting Evaluation Run"
    puts "=" * 80
    puts "  Dataset: #{dataset.name} (#{dataset.sample_count} samples)"
    puts "  Type: #{dataset.eval_type}"
    puts "  Model: #{model}"
    puts "  Provider: #{provider}"
    puts "  Run Name: #{run_name}"
    puts

    eval_run = Eval::Run.create!(
      dataset: dataset,
      provider: provider,
      model: model,
      name: run_name
    )

    runner = dataset.runner_class.new(eval_run)

    puts "Running evaluation..."
    start_time = Time.current

    begin
      result = runner.run
      duration = (Time.current - start_time).round(1)

      puts
      puts "=" * 80
      puts "Evaluation Complete"
      puts "=" * 80
      puts "  Status: #{result.status}"
      puts "  Duration: #{duration}s"
      puts "  Run ID: #{result.id}"
      puts
      puts "Metrics:"
      result.metrics.each do |key, value|
        next if value.is_a?(Hash) # Skip nested metrics for summary
        puts "  #{key}: #{format_metric_value(value)}"
      end

      # Show difficulty breakdown if available
      if result.metrics["by_difficulty"].present?
        puts
        puts "By Difficulty:"
        result.metrics["by_difficulty"].each do |difficulty, stats|
          puts "  #{difficulty}: #{stats['accuracy']}% accuracy (#{stats['correct']}/#{stats['count']})"
        end
      end
    rescue => e
      puts
      puts "Evaluation FAILED: #{e.message}"
      puts e.backtrace.first(5).join("\n") if ENV["DEBUG"]
      exit 1
    end
  end

  desc "Compare multiple models on a dataset"
  task :compare, [ :dataset_name ] => :environment do |_t, args|
    dataset_name = args[:dataset_name] || ENV["DATASET"]
    models = (ENV["MODELS"] || "gpt-4.1,gpt-4o-mini").split(",").map(&:strip)
    provider = ENV["PROVIDER"] || "openai"

    if dataset_name.blank?
      puts "Usage: MODELS=model1,model2 rake evals:compare[dataset_name]"
      exit 1
    end

    dataset = Eval::Dataset.find_by!(name: dataset_name)

    puts "=" * 80
    puts "Model Comparison"
    puts "=" * 80
    puts "  Dataset: #{dataset.name}"
    puts "  Models: #{models.join(', ')}"
    puts

    runs = models.map do |model|
      puts "Running evaluation for #{model}..."

      eval_run = Eval::Run.create!(
        dataset: dataset,
        provider: provider,
        model: model,
        name: "compare_#{model}_#{Time.current.to_i}"
      )

      runner = dataset.runner_class.new(eval_run)
      runner.run
    end

    puts
    puts "=" * 80
    puts "Comparison Results"
    puts "=" * 80
    puts

    reporter = Eval::Reporters::ComparisonReporter.new(runs)
    puts reporter.to_table

    summary = reporter.summary
    if summary.present?
      puts
      puts "Recommendations:"
      puts "  Best Accuracy: #{summary[:best_accuracy][:model]} (#{summary[:best_accuracy][:value]}%)"
      puts "  Lowest Cost: #{summary[:lowest_cost][:model]} ($#{summary[:lowest_cost][:value]})"
      puts "  Fastest: #{summary[:fastest][:model]} (#{summary[:fastest][:value]}ms)"
      puts
      puts "  #{summary[:recommendation]}"
    end

    # Export to CSV if requested
    if ENV["CSV"].present?
      csv_path = reporter.to_csv(ENV["CSV"])
      puts
      puts "Exported to: #{csv_path}"
    end
  end

  desc "Generate report for specific runs"
  task :report, [ :run_ids ] => :environment do |_t, args|
    run_ids = (args[:run_ids] || ENV["RUN_IDS"])&.split(",")

    runs = if run_ids.present?
      Eval::Run.where(id: run_ids)
    else
      Eval::Run.completed.order(created_at: :desc).limit(5)
    end

    if runs.empty?
      puts "No runs found."
      exit 1
    end

    reporter = Eval::Reporters::ComparisonReporter.new(runs)

    puts reporter.to_table

    summary = reporter.summary
    if summary.present?
      puts
      puts "Summary:"
      puts "  Best Accuracy: #{summary[:best_accuracy][:model]} (#{summary[:best_accuracy][:value]}%)"
      puts "  Lowest Cost: #{summary[:lowest_cost][:model]} ($#{summary[:lowest_cost][:value]})"
      puts "  Fastest: #{summary[:fastest][:model]} (#{summary[:fastest][:value]}ms)"
    end

    if ENV["CSV"].present?
      csv_path = reporter.to_csv(ENV["CSV"])
      puts
      puts "Exported to: #{csv_path}"
    end
  end

  desc "Quick smoke test to verify provider configuration"
  task smoke_test: :environment do
    puts "Running smoke test..."

    provider = Provider::Registry.get_provider(:openai)

    unless provider
      puts "FAIL: OpenAI provider not configured"
      puts "Set OPENAI_ACCESS_TOKEN environment variable or configure in settings"
      exit 1
    end

    puts "  Provider: #{provider.provider_name}"
    puts "  Model: #{provider.instance_variable_get(:@default_model)}"

    # Test with a single categorization sample
    result = provider.auto_categorize(
      transactions: [
        { id: "test", amount: 10, classification: "expense", description: "McDonalds" }
      ],
      user_categories: [
        { id: "1", name: "Food & Drink", classification: "expense" }
      ]
    )

    if result.success?
      category = result.data.first&.category_name
      puts "  Test result: #{category || 'null'}"
      puts
      puts "PASS: Provider is working correctly"
    else
      puts "FAIL: #{result.error.message}"
      exit 1
    end
  end

  desc "Run CI regression test"
  task ci_regression: :environment do
    dataset_name = ENV["EVAL_DATASET"] || "categorization_golden_v1"
    model = ENV["EVAL_MODEL"] || "gpt-4.1-mini"
    threshold = (ENV["EVAL_THRESHOLD"] || "80").to_f

    dataset = Eval::Dataset.find_by(name: dataset_name)

    unless dataset
      puts "Dataset '#{dataset_name}' not found. Skipping CI regression test."
      exit 0
    end

    # Get baseline from last successful run
    baseline_run = dataset.runs.completed.for_model(model).order(created_at: :desc).first

    # Run new evaluation
    eval_run = Eval::Run.create!(
      dataset: dataset,
      provider: "openai",
      model: model,
      name: "ci_regression_#{Time.current.to_i}"
    )

    runner = dataset.runner_class.new(eval_run)
    result = runner.run

    current_accuracy = result.metrics["accuracy"] || 0

    puts "CI Regression Test Results:"
    puts "  Model: #{model}"
    puts "  Current Accuracy: #{current_accuracy}%"

    if baseline_run
      baseline_accuracy = baseline_run.metrics["accuracy"] || 0
      puts "  Baseline Accuracy: #{baseline_accuracy}%"

      accuracy_diff = current_accuracy - baseline_accuracy

      if accuracy_diff < -5
        puts
        puts "REGRESSION DETECTED!"
        puts "Accuracy dropped by #{accuracy_diff.abs}% (threshold: 5%)"
        exit 1
      end

      puts "  Difference: #{accuracy_diff > 0 ? '+' : ''}#{accuracy_diff.round(2)}%"
    end

    if current_accuracy < threshold
      puts
      puts "BELOW THRESHOLD!"
      puts "Accuracy #{current_accuracy}% is below required #{threshold}%"
      exit 1
    end

    puts
    puts "CI Regression Test PASSED"
  end

  desc "List recent evaluation runs"
  task list_runs: :environment do
    runs = Eval::Run.order(created_at: :desc).limit(20)

    if runs.empty?
      puts "No runs found."
      next
    end

    puts "=" * 100
    puts "Recent Evaluation Runs"
    puts "=" * 100

    runs.each do |run|
      status_icon = case run.status
      when "completed" then "[OK]"
      when "failed" then "[FAIL]"
      when "running" then "[...]"
      else "[?]"
      end

      accuracy = run.metrics["accuracy"] ? "#{run.metrics['accuracy']}%" : "-"

      puts "#{status_icon} #{run.id[0..7]} | #{run.model.ljust(15)} | #{run.dataset.name.ljust(25)} | #{accuracy.rjust(8)} | #{run.created_at.strftime('%Y-%m-%d %H:%M')}"
    end
  end

  desc "Show details for a specific run"
  task :show_run, [ :run_id ] => :environment do |_t, args|
    run_id = args[:run_id] || ENV["RUN_ID"]

    if run_id.blank?
      puts "Usage: rake evals:show_run[run_id]"
      exit 1
    end

    run = Eval::Run.find_by(id: run_id) || Eval::Run.find_by("id::text LIKE ?", "#{run_id}%")

    unless run
      puts "Run not found: #{run_id}"
      exit 1
    end

    puts "=" * 80
    puts "Evaluation Run Details"
    puts "=" * 80
    puts
    puts "Run ID: #{run.id}"
    puts "Name: #{run.name}"
    puts "Dataset: #{run.dataset.name}"
    puts "Model: #{run.model}"
    puts "Provider: #{run.provider}"
    puts "Status: #{run.status}"
    puts "Created: #{run.created_at}"
    puts "Duration: #{run.duration_seconds}s" if run.duration_seconds

    if run.error_message.present?
      puts
      puts "Error: #{run.error_message}"
    end

    if run.metrics.present?
      puts
      puts "Metrics:"
      run.metrics.each do |key, value|
        if value.is_a?(Hash)
          puts "  #{key}:"
          value.each { |k, v| puts "    #{k}: #{v}" }
        else
          puts "  #{key}: #{format_metric_value(value)}"
        end
      end
    end

    # Show sample of incorrect results
    incorrect = run.results.incorrect.limit(5)
    if incorrect.any?
      puts
      puts "Sample Incorrect Results (#{run.results.incorrect.count} total):"
      incorrect.each do |result|
        puts "  Sample: #{result.sample_id[0..7]}"
        puts "    Expected: #{result.sample.expected_output}"
        puts "    Actual: #{result.actual_output}"
        puts
      end
    end
  end

  private

    def format_metric_value(value)
      case value
      when Float
        value.round(4)
      when BigDecimal
        value.to_f.round(4)
      else
        value
      end
    end
end
