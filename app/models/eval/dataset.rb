class Eval::Dataset < ApplicationRecord
  self.table_name = "eval_datasets"

  has_many :samples, class_name: "Eval::Sample", foreign_key: :eval_dataset_id, dependent: :destroy
  has_many :runs, class_name: "Eval::Run", foreign_key: :eval_dataset_id, dependent: :destroy

  validates :name, presence: true, uniqueness: true
  validates :eval_type, presence: true, inclusion: { in: %w[categorization merchant_detection chat] }
  validates :version, presence: true

  scope :active, -> { where(active: true) }
  scope :for_categorization, -> { where(eval_type: "categorization") }
  scope :for_merchant_detection, -> { where(eval_type: "merchant_detection") }
  scope :for_chat, -> { where(eval_type: "chat") }

  # Import dataset from a YAML file
  def self.import_from_yaml(file_path)
    data = YAML.load_file(file_path, permitted_classes: [ Symbol, Date, Time ])

    transaction do
      dataset = find_or_initialize_by(name: data["name"])
      dataset.assign_attributes(
        description: data["description"],
        eval_type: data["eval_type"],
        version: data["version"] || "1.0",
        metadata: data["metadata"] || {},
        active: true
      )
      dataset.save!

      # Clear existing samples if reimporting
      dataset.samples.destroy_all

      # Shared context for all samples
      shared_context = data["context"] || {}

      # Import samples
      samples_data = data["samples"] || []
      samples_data.each_with_index do |sample_data, index|
        dataset.samples.create!(
          id: sample_id(dataset.name, index),
          input_data: sample_data["input"],
          expected_output: sample_data["expected"],
          context_data: sample_data["context"] || shared_context,
          difficulty: sample_data["difficulty"] || "medium",
          tags: sample_data["tags"] || [],
          metadata: sample_data["metadata"] || {}
        )
      end

      dataset.update!(sample_count: dataset.samples.count)
      dataset
    end
  end

  # The same id for a dataset's nth sample on every import, so the ids sent to a model, the
  # batches and the train/test split match a recording (the recorded evals replay by them).
  def self.sample_id(dataset_name, index) = Digest::UUID.uuid_v5(Digest::UUID::URL_NAMESPACE, "sure:eval:#{dataset_name}:#{index}")

  # Export dataset to YAML format
  def export_to_yaml
    {
      "name" => name,
      "description" => description,
      "eval_type" => eval_type,
      "version" => version,
      "metadata" => metadata,
      "context" => samples.first&.context_data || {},
      "samples" => samples.map do |sample|
        {
          "id" => sample.id,
          "difficulty" => sample.difficulty,
          "tags" => sample.tags,
          "input" => sample.input_data,
          "expected" => sample.expected_output,
          "metadata" => sample.metadata
        }.compact
      end
    }.to_yaml
  end

  # Generate summary statistics
  def statistics
    {
      total_samples: samples.count,
      by_difficulty: samples.group(:difficulty).count,
      by_tags: samples.flat_map(&:tags).tally.sort_by { |_, v| -v }.to_h
    }
  end

  # Get the appropriate runner class for this dataset type
  def runner_class
    case eval_type
    when "categorization"
      Eval::Runners::CategorizationRunner
    when "merchant_detection"
      Eval::Runners::MerchantDetectionRunner
    when "chat"
      Eval::Runners::ChatRunner
    else
      raise "Unknown eval_type: #{eval_type}"
    end
  end

  # Get the appropriate metrics class for this dataset type
  def metrics_class
    case eval_type
    when "categorization"
      Eval::Metrics::CategorizationMetrics
    when "merchant_detection"
      Eval::Metrics::MerchantDetectionMetrics
    when "chat"
      Eval::Metrics::ChatMetrics
    else
      raise "Unknown eval_type: #{eval_type}"
    end
  end
end
