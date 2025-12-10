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
      name: run_name,
      status: "pending"
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
        name: "compare_#{model}_#{Time.current.to_i}",
        status: "pending"
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
      name: "ci_regression_#{Time.current.to_i}",
      status: "pending"
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

  # =============================================================================
  # Langfuse Integration
  # =============================================================================

  namespace :langfuse do
    desc "Check Langfuse configuration"
    task check: :environment do
      begin
        client = Eval::Langfuse::Client.new
        puts "✓ Langfuse credentials configured"

        # Try to list datasets to verify connection
        response = client.list_datasets(limit: 1)
        puts "✓ Successfully connected to Langfuse"
        puts "  Region: #{ENV['LANGFUSE_REGION'] || 'us (default)'}"
      rescue Eval::Langfuse::Client::ConfigurationError => e
        puts "✗ #{e.message}"
        exit 1
      rescue Eval::Langfuse::Client::ApiError => e
        puts "✗ Failed to connect to Langfuse: #{e.message}"
        exit 1
      end
    end

    desc "Upload dataset to Langfuse"
    task :upload_dataset, [ :dataset_name ] => :environment do |_t, args|
      dataset_name = args[:dataset_name] || ENV["DATASET"]

      if dataset_name.blank?
        puts "Usage: rake evals:langfuse:upload_dataset[dataset_name]"
        puts "   or: DATASET=name rake evals:langfuse:upload_dataset"
        exit 1
      end

      dataset = Eval::Dataset.find_by(name: dataset_name)

      if dataset.nil?
        puts "Error: Dataset '#{dataset_name}' not found"
        puts "Available datasets:"
        Eval::Dataset.pluck(:name).each { |n| puts "  - #{n}" }
        exit 1
      end

      puts "=" * 80
      puts "Uploading Dataset to Langfuse"
      puts "=" * 80
      puts "  Dataset: #{dataset.name}"
      puts "  Type: #{dataset.eval_type}"
      puts "  Samples: #{dataset.sample_count}"
      puts

      begin
        exporter = Eval::Langfuse::DatasetExporter.new(dataset)
        result = exporter.export

        puts
        puts "✓ Successfully uploaded dataset to Langfuse"
        puts "  Langfuse dataset name: #{result[:dataset_name]}"
        puts "  Items exported: #{result[:items_exported]}"
        puts
        puts "View in Langfuse: https://cloud.langfuse.com/project/datasets"
      rescue Eval::Langfuse::Client::ConfigurationError => e
        puts "✗ #{e.message}"
        exit 1
      rescue Eval::Langfuse::Client::ApiError => e
        puts "✗ Langfuse API error: #{e.message}"
        exit 1
      end
    end

    desc "Run experiment in Langfuse"
    task :run_experiment, [ :dataset_name, :model ] => :environment do |_t, args|
      dataset_name = args[:dataset_name] || ENV["DATASET"]
      model = args[:model] || ENV["MODEL"] || "gpt-4.1"
      provider = ENV["PROVIDER"] || "openai"
      run_name = ENV["RUN_NAME"]

      if dataset_name.blank?
        puts "Usage: rake evals:langfuse:run_experiment[dataset_name,model]"
        puts "   or: DATASET=name MODEL=gpt-4.1 rake evals:langfuse:run_experiment"
        puts
        puts "Optional environment variables:"
        puts "  PROVIDER=openai (default)"
        puts "  RUN_NAME=custom_run_name"
        exit 1
      end

      dataset = Eval::Dataset.find_by(name: dataset_name)

      if dataset.nil?
        puts "Error: Dataset '#{dataset_name}' not found"
        puts "Available datasets:"
        Eval::Dataset.pluck(:name).each { |n| puts "  - #{n}" }
        exit 1
      end

      puts "=" * 80
      puts "Running Langfuse Experiment"
      puts "=" * 80
      puts "  Dataset: #{dataset.name} (#{dataset.sample_count} samples)"
      puts "  Type: #{dataset.eval_type}"
      puts "  Model: #{model}"
      puts "  Provider: #{provider}"
      puts

      begin
        runner = Eval::Langfuse::ExperimentRunner.new(
          dataset,
          model: model,
          provider: provider
        )

        start_time = Time.current
        result = runner.run(run_name: run_name)
        duration = (Time.current - start_time).round(1)

        puts
        puts "=" * 80
        puts "Experiment Complete"
        puts "=" * 80
        puts "  Run Name: #{result[:run_name]}"
        puts "  Duration: #{duration}s"
        puts
        puts "Results:"
        puts "  Accuracy: #{result[:metrics][:accuracy]}%"
        puts "  Correct: #{result[:metrics][:correct]}/#{result[:metrics][:total]}"
        puts "  Avg Latency: #{result[:metrics][:avg_latency_ms]}ms"
        puts
        puts "View in Langfuse:"
        puts "  Dataset: https://cloud.langfuse.com/project/datasets"
        puts "  Traces: https://cloud.langfuse.com/project/traces"
      rescue Eval::Langfuse::Client::ConfigurationError => e
        puts "✗ #{e.message}"
        exit 1
      rescue Eval::Langfuse::Client::ApiError => e
        puts "✗ Langfuse API error: #{e.message}"
        exit 1
      rescue => e
        puts "✗ Error: #{e.message}"
        puts e.backtrace.first(5).join("\n") if ENV["DEBUG"]
        exit 1
      end
    end

    desc "List datasets in Langfuse"
    task list_datasets: :environment do
      begin
        client = Eval::Langfuse::Client.new
        response = client.list_datasets(limit: 100)

        datasets = response["data"] || []

        if datasets.empty?
          puts "No datasets found in Langfuse."
          puts "Upload a dataset with: rake evals:langfuse:upload_dataset[dataset_name]"
          next
        end

        puts "=" * 80
        puts "Langfuse Datasets"
        puts "=" * 80
        puts

        datasets.each do |ds|
          puts "  #{ds['name']}"
          puts "    Description: #{ds['description']}" if ds["description"].present?
          puts "    Created: #{ds['createdAt']}"
          puts "    Metadata: #{ds['metadata']}" if ds["metadata"].present?
          puts
        end
      rescue Eval::Langfuse::Client::ConfigurationError => e
        puts "✗ #{e.message}"
        exit 1
      rescue Eval::Langfuse::Client::ApiError => e
        puts "✗ Langfuse API error: #{e.message}"
        exit 1
      end
    end
  end

  desc "Export manually categorized transactions as golden data"
  task :export_manual_categories, [ :family_id ] => :environment do |_t, args|
    family_id = args[:family_id] || ENV["FAMILY_ID"]
    output_path = ENV["OUTPUT"] || "db/eval_data/categorization_manual_export.yml"
    limit = (ENV["LIMIT"] || 500).to_i

    if family_id.blank?
      puts "Usage: rake evals:export_manual_categories[family_id]"
      puts "   or: FAMILY_ID=uuid rake evals:export_manual_categories"
      puts
      puts "Optional environment variables:"
      puts "  OUTPUT=path/to/output.yml (default: db/eval_data/categorization_manual_export.yml)"
      puts "  LIMIT=500 (default: 500)"
      exit 1
    end

    family = Family.find_by(id: family_id)

    if family.nil?
      puts "Error: Family '#{family_id}' not found"
      exit 1
    end

    puts "=" * 80
    puts "Exporting Manually Categorized Transactions"
    puts "=" * 80
    puts "  Family: #{family.name}"
    puts "  Output: #{output_path}"
    puts "  Limit: #{limit}"
    puts

    # Find transactions that have:
    # 1. A category assigned
    # 2. locked_attributes contains "category_id" (meaning user manually set it)
    # 3. No DataEnrichment record for category_id (meaning it wasn't set by AI/rules/etc)
    manually_categorized = Transaction
      .joins(:entry)
      .joins("INNER JOIN accounts ON accounts.id = entries.account_id")
      .where(accounts: { family_id: family_id })
      .where.not(category_id: nil)
      .where("transactions.locked_attributes ? 'category_id'")
      .where.not(
        id: DataEnrichment
          .where(enrichable_type: "Transaction", attribute_name: "category_id")
          .select(:enrichable_id)
      )
      .includes(:category, entry: :account)
      .limit(limit)

    count = manually_categorized.count

    if count == 0
      puts "No manually categorized transactions found."
      puts
      puts "Manually categorized transactions are those where:"
      puts "  - User set a category manually (locked_attributes contains 'category_id')"
      puts "  - Category was NOT set by AI, rules, or data enrichment sources"
      exit 0
    end

    puts "Found #{count} manually categorized transactions"
    puts

    # Build category context from family's categories
    categories = family.categories.includes(:parent).map do |cat|
      {
        "id" => cat.id.to_s,
        "name" => cat.name,
        "classification" => cat.classification,
        "is_subcategory" => cat.subcategory?,
        "parent_id" => cat.parent_id&.to_s
      }.compact
    end

    # Build samples
    samples = manually_categorized.map.with_index do |txn, idx|
      entry = txn.entry
      sample_id = "manual_#{idx + 1}"

      {
        "id" => sample_id,
        "difficulty" => "manual",
        "tags" => [ txn.category.name.parameterize.underscore, "manual_export" ],
        "input" => {
          "id" => txn.id.to_s,
          "amount" => entry.amount.to_f.abs,
          "classification" => entry.classification,
          "description" => entry.name
        },
        "expected" => {
          "category_name" => txn.category.name
        }
      }
    end

    # Build output structure
    output = {
      "name" => "categorization_manual_export",
      "description" => "Golden dataset exported from manually categorized user transactions",
      "eval_type" => "categorization",
      "version" => "1.0",
      "metadata" => {
        "created_at" => Time.current.strftime("%Y-%m-%d"),
        "source" => "manual_export",
        "family_id" => family_id,
        "exported_count" => samples.size
      },
      "context" => {
        "categories" => categories
      },
      "samples" => samples
    }

    # Write to file
    FileUtils.mkdir_p(File.dirname(output_path))
    File.write(output_path, output.to_yaml)

    puts "✓ Successfully exported #{samples.size} samples"
    puts "  Difficulty: manual"
    puts
    puts "Output written to: #{output_path}"
    puts
    puts "To import this dataset, run:"
    puts "  rake evals:import_dataset[#{output_path}]"
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
