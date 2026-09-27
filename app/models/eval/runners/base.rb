class Eval::Runners::Base
  attr_reader :eval_run

  def initialize(eval_run)
    @eval_run = eval_run
  end

  def run
    eval_run.start!

    begin
      process_samples
      metrics = calculate_metrics
      eval_run.complete!(metrics)
    rescue => e
      eval_run.fail!(e)
      raise
    end

    eval_run
  end

  protected

    def process_samples
      raise NotImplementedError, "Subclasses must implement #process_samples"
    end

    def calculate_metrics
      raise NotImplementedError, "Subclasses must implement #calculate_metrics"
    end

    # The whole dataset unless the run asks for one side of a train/test split.
    # Bayes has to be trained on held-out samples, so every provider it is
    # compared against must be evaluated on the same test set — a provider
    # scored over the full dataset is not comparable to one scored over the
    # residual. See Eval::Runners::SampleSplit.
    def samples
      return eval_run.dataset.samples if split_role.blank?

      sample_split.for_role(split_role)
    end

    def split_role
      eval_run.provider_config["split_role"].presence
    end

    def sample_split
      @sample_split ||= Eval::Runners::SampleSplit.new(
        eval_run.dataset.samples,
        seed: eval_run.provider_config.fetch("split_seed", Eval::Runners::SampleSplit::DEFAULT_SEED),
        train_ratio: eval_run.provider_config.fetch("split_ratio", Eval::Runners::SampleSplit::DEFAULT_TRAIN_RATIO)
      )
    end

    def provider
      @provider ||= build_provider
    end

    def model
      eval_run.model
    end

  private

    def build_provider
      Eval::ProviderFactory.build(
        provider: eval_run.provider,
        model: model,
        config: eval_run.provider_config
      )
    end

    def record_result(sample:, actual_output:, correct:, **attributes)
      eval_run.results.create!(
        sample: sample,
        actual_output: actual_output,
        correct: correct,
        **attributes
      )
    end

    def log_progress(message)
      Rails.logger.info("[Eval::Runner] #{message}")
    end
end
