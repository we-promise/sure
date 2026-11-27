require "test_helper"
require "puma/configuration"

class PumaConfigTest < ActiveSupport::TestCase
  test "WEB_CONCURRENCY=1 runs a single process, not a one-worker cluster" do
    assert_equal 0, production_workers("WEB_CONCURRENCY" => "1")
  end

  test "an unset WEB_CONCURRENCY runs a single process" do
    assert_equal 0, production_workers("WEB_CONCURRENCY" => nil)
  end

  test "WEB_CONCURRENCY above 1 runs that many workers" do
    assert_equal 3, production_workers("WEB_CONCURRENCY" => "3")
  end

  private
    def production_workers(env)
      with_env_overrides(env.merge("RAILS_ENV" => "production")) do
        config = Puma::Configuration.new({ config_files: [ Rails.root.join("config/puma.rb").to_s ] }, {}, ENV.to_h)
        config.clamp
        config.options[:workers]
      end
    end
end
