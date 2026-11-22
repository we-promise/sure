require "sidekiq/capsule"

# Runs Sidekiq inside the Puma process for single-container deploys, so the
# app is loaded once instead of in a separate worker. Queues and capsules come
# from config/sidekiq.yml, matching what `bundle exec sidekiq` would run.
module EmbeddedSidekiq
  CONFIG_PATH = File.expand_path("../config/sidekiq.yml", __dir__)

  class << self
    def build(config_path = CONFIG_PATH)
      opts = load_options(config_path)
      Sidekiq.configure_embed { |config| apply(config, opts) }
    end

    def apply(config, opts)
      config.concurrency = opts[:concurrency]
      config.queues = opts[:queues].map { |name, weight| [ name.to_s, weight.to_s ] }
      opts[:capsules]&.each do |name, capsule_opts|
        config.capsule(name.to_s) do |capsule|
          capsule.concurrency = capsule_opts[:concurrency]
          capsule.queues = capsule_opts[:queues]
        end
      end
      config
    end

    def load_options(config_path = CONFIG_PATH)
      erb = ERB.new(File.read(config_path), trim_mode: "-")
      YAML.safe_load(erb.result, permitted_classes: [ Symbol ], aliases: true).deep_symbolize_keys
    end
  end
end
