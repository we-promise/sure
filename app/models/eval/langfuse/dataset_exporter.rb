class Eval::Langfuse::DatasetExporter
  attr_reader :dataset, :client

  def initialize(dataset, client: nil)
    @dataset = dataset
    @client = client || Eval::Langfuse::Client.new
  end

  def export
    Rails.logger.info("[Langfuse] Exporting dataset '#{dataset.name}' to Langfuse...")

    # Create or update dataset in Langfuse
    create_langfuse_dataset

    # Export all samples as dataset items
    exported_count = export_samples

    Rails.logger.info("[Langfuse] Exported #{exported_count} items to dataset '#{langfuse_dataset_name}'")

    {
      dataset_name: langfuse_dataset_name,
      items_exported: exported_count
    }
  end

  private

    def langfuse_dataset_name
      # Use a consistent naming convention
      "eval_#{dataset.name}"
    end

    def create_langfuse_dataset
      client.create_dataset(
        name: langfuse_dataset_name,
        description: dataset.description || "Evaluation dataset: #{dataset.name}",
        metadata: {
          eval_type: dataset.eval_type,
          version: dataset.version,
          source: "sure_eval_framework",
          exported_at: Time.current.iso8601
        }
      )
    rescue Eval::Langfuse::Client::ApiError => e
      # Dataset might already exist (409 conflict), which is fine
      raise unless e.status == 409

      Rails.logger.info("[Langfuse] Dataset '#{langfuse_dataset_name}' already exists, updating items...")
    end

    def export_samples
      count = 0

      dataset.samples.find_each do |sample|
        export_sample(sample)
        count += 1

        # Log progress every 25 samples
        if (count % 25).zero?
          Rails.logger.info("[Langfuse] Exported #{count}/#{dataset.sample_count} items...")
          print "  Exported #{count}/#{dataset.sample_count} items...\r"
        end

        # Small delay to avoid rate limiting (Langfuse free tier has limits)
        sleep(0.1)
      end

      count
    end

    def export_sample(sample)
      client.create_dataset_item(
        dataset_name: langfuse_dataset_name,
        id: sample.id, # Use the same ID for idempotency
        input: build_input(sample),
        expected_output: build_expected_output(sample),
        metadata: build_metadata(sample)
      )
    end

    def build_input(sample)
      case dataset.eval_type
      when "categorization"
        {
          transaction: sample.input_data,
          categories: sample.categories_context
        }
      when "merchant_detection"
        {
          transaction: sample.input_data,
          merchants: sample.merchants_context
        }
      when "chat"
        {
          prompt: sample.chat_prompt,
          mock_data: sample.mock_data
        }
      else
        sample.input_data
      end
    end

    def build_expected_output(sample)
      sample.expected_output
    end

    def build_metadata(sample)
      {
        difficulty: sample.difficulty,
        tags: sample.tags,
        eval_type: dataset.eval_type,
        sample_id: sample.id
      }.merge(sample.metadata || {})
    end
end
