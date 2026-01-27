require "test_helper"

class Demo::ModeTest < ActiveSupport::TestCase
  test "demo_mode? honors DEMO_MODE env flag" do
    with_env("DEMO_MODE" => "1") do
      assert Demo::Mode.demo_mode?
    end
  end

  test "demo_mode? matches APP_DOMAIN against demo hosts" do
    demo_host = demo_hosts.first

    with_env("DEMO_MODE" => nil, "APP_DOMAIN" => demo_host) do
      assert Demo::Mode.demo_mode?
    end
  end

  private
    def with_env(overrides)
      original = ENV.to_hash.slice(*overrides.keys)

      overrides.each do |key, value|
        value.nil? ? ENV.delete(key) : ENV[key] = value
      end

      yield
    ensure
      overrides.each_key do |key|
        if original[key].nil?
          ENV.delete(key)
        else
          ENV[key] = original[key]
        end
      end
    end

    def demo_hosts
      config = Rails.application.config_for(:demo)
      hosts = config["hosts"]
      return hosts if hosts.present?

      YAML.load_file(Rails.root.join("config/demo.yml")).dig("default", "hosts")
    end
end
