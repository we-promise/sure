class Demo::Mode
  DEMO_MODE_ENV_KEY = "DEMO_MODE".freeze
  APP_DOMAIN_ENV_KEY = "APP_DOMAIN".freeze

  class << self
    def demo_mode?
      env_demo_mode? || app_domain_demo_host?
    end

    private
      def env_demo_mode?
        ENV[DEMO_MODE_ENV_KEY].to_s == "1"
      end

      def app_domain_demo_host?
        app_domain = ENV[APP_DOMAIN_ENV_KEY].to_s.strip
        return false if app_domain.blank?

        demo_hosts.include?(app_domain)
      end

      def demo_hosts
        config = demo_config
        config["hosts"] || config[:hosts] || []
      end

      def demo_config
        config = Rails.application.config_for(:demo)
        return config if config["hosts"].present?

        YAML.load_file(Rails.root.join("config/demo.yml")).fetch("default", {})
      rescue RuntimeError, Errno::ENOENT, Psych::SyntaxError
        {}
      end
  end
end
