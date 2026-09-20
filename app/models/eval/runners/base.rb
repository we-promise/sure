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

    def samples
      eval_run.dataset.samples
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
