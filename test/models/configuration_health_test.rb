require "test_helper"

class ConfigurationHealthTest < ActiveSupport::TestCase
  setup do
    ApplicationMailer.stubs(:perform_deliveries).returns(true)
    ApplicationMailer.stubs(:delivery_method).returns(:smtp)
    ApplicationMailer.stubs(:smtp_settings).returns({ address: "smtp.example.test", port: "587" })
    ApplicationMailer.stubs(:default).returns({ from: "Sure <sender@example.test>" })
    ApplicationMailer.stubs(:default_url_options).returns({ host: "sure.example.test" })
  end

  test "missing SMTP address is not configured and never sends email" do
    ApplicationMailer.stubs(:smtp_settings).returns({ address: nil, port: nil })
    ApplicationMailer.expects(:mail).never

    check = ConfigurationHealth.new.smtp

    assert_equal :not_configured, check.status
    assert_equal [ :address, :port ], check.issues
  end

  test "an unauthenticated SMTP relay is configured without requiring credentials" do
    check = ConfigurationHealth.new.smtp

    assert_equal :configured, check.status
    assert_empty check.issues
    assert_equal :neutral, check.tone
  end

  test "SMTP uses running mailer settings rather than changed environment variables" do
    ClimateControl.modify("SMTP_ADDRESS" => nil, "EMAIL_SENDER" => nil, "APP_DOMAIN" => nil) do
      assert_equal :configured, ConfigurationHealth.new.smtp.status
    end
  end

  test "SMTP credentials must be supplied together and are never included in results" do
    ApplicationMailer.stubs(:smtp_settings).returns({
      address: "private-smtp.example.test", port: 587, user_name: "private-username", password: nil
    })
    check = ConfigurationHealth.new.smtp
    assert_equal :incomplete, check.status
    assert_equal [ :authentication ], check.issues

    ApplicationMailer.stubs(:smtp_settings).returns({
      address: "private-smtp.example.test", port: 587, user_name: "private-username", password: "private-password"
    })
    check = ConfigurationHealth.new.smtp
    assert_equal :configured, check.status
    assert_no_match(/private-/, check.inspect)
  end

  test "missing or placeholder sender and missing link domain are incomplete" do
    [ nil, "", "Sure", "Sure <>", "not an email <", "Sure <sender@sure.local>" ].each do |sender|
      ApplicationMailer.stubs(:default).returns({ from: sender })
      ApplicationMailer.stubs(:default_url_options).returns({})

      check = ConfigurationHealth.new.smtp
      assert_equal :incomplete, check.status
      assert_equal [ :sender, :app_domain ], check.issues
    end
  end

  test "SMTP port must be a valid port number" do
    [ nil, "", "smtp", "0", "65536", -1 ].each do |port|
      ApplicationMailer.stubs(:smtp_settings).returns({ address: "smtp.example.test", port: port })
      assert_includes ConfigurationHealth.new.smtp.issues, :port
    end
  end

  test "disabled delivery is distinct from missing SMTP configuration" do
    ApplicationMailer.stubs(:perform_deliveries).returns(false)
    ApplicationMailer.expects(:smtp_settings).never

    assert_equal :disabled, ConfigurationHealth.new.smtp.status
  end

  test "non SMTP delivery methods are not assessed as missing SMTP" do
    ApplicationMailer.stubs(:delivery_method).returns(:letter_opener)
    ApplicationMailer.expects(:smtp_settings).never

    assert_equal :not_checked, ConfigurationHealth.new.smtp.status
  end

  test "selected market providers use the existing ENV precedence and no live checks" do
    Setting.stubs(:securities_providers).returns("yahoo_finance")
    Setting.stubs(:twelve_data_api_key).returns("database-key")
    Provider::TwelveData.expects(:new).with("environment-key").returns(stub("provider without probe methods"))

    ClimateControl.modify("SECURITIES_PROVIDERS" => "twelve_data", "TWELVE_DATA_API_KEY" => "environment-key") do
      check = ConfigurationHealth.new.securities
      assert_equal :configured, check.status
      assert_equal [ :twelve_data ], check.providers.map(&:key)
      assert_no_match(/environment-key|database-key/, check.inspect)
    end
  end

  test "blank environment API key falls back to the database key" do
    Setting.stubs(:enabled_securities_providers).returns([ "twelve_data" ])
    Setting.stubs(:twelve_data_api_key).returns("database-key")
    Provider::TwelveData.expects(:new).with("database-key").returns(stub("provider"))

    ClimateControl.modify("TWELVE_DATA_API_KEY" => "") do
      assert_equal :configured, ConfigurationHealth.new.securities.status
    end
  end

  test "keyless public providers are configured without API keys" do
    Setting.stubs(:enabled_securities_providers).returns([ "yahoo_finance", "mfapi", "binance_public", "moex_public" ])
    Provider::YahooFinance.any_instance.expects(:health_status).never
    Provider::YahooFinance.any_instance.expects(:healthy?).never

    assert_equal :configured, ConfigurationHealth.new.securities.status
  end

  test "missing selected API keys are not configured" do
    Setting.stubs(:enabled_securities_providers).returns([ "twelve_data" ])
    Setting.stubs(:twelve_data_api_key).returns(nil)

    ClimateControl.modify("TWELVE_DATA_API_KEY" => nil) do
      check = ConfigurationHealth.new.securities
      assert_equal :not_configured, check.status
      assert_equal :not_configured, check.providers.first.status
    end
  end

  test "mixed providers identify incomplete configuration without hiding the working selection" do
    Setting.stubs(:enabled_securities_providers).returns([ "yahoo_finance", "twelve_data" ])
    Setting.stubs(:twelve_data_api_key).returns(nil)

    ClimateControl.modify("TWELVE_DATA_API_KEY" => nil) do
      check = ConfigurationHealth.new.securities
      assert_equal :incomplete, check.status
      assert_equal [ :configured, :not_configured ], check.providers.map(&:status)
    end
  end

  test "no enabled market provider is disabled" do
    Setting.stubs(:enabled_securities_providers).returns([])

    assert_equal :disabled, ConfigurationHealth.new.securities.status
  end

  test "invalid provider selections are not invoked or exposed" do
    Setting.stubs(:enabled_securities_providers).returns([ "credential-pasted-in-wrong-setting" ])
    Provider::Registry.expects(:get_provider).never

    check = ConfigurationHealth.new.securities
    assert_equal :incomplete, check.status
    assert_equal :unknown, check.providers.first.key
    assert_equal :invalid, check.providers.first.status
    assert_no_match(/credential-pasted/, check.inspect)
  end

  test "exchange rates honor the ENV provider selection and support keyless providers" do
    Setting.stubs(:exchange_rate_provider).returns("twelve_data")
    Provider::Frankfurter.any_instance.expects(:healthy?).never

    ClimateControl.modify("EXCHANGE_RATE_PROVIDER" => "frankfurter") do
      check = ConfigurationHealth.new.exchange_rates
      assert_equal :configured, check.status
      assert_equal :frankfurter, check.providers.first.key
    end
  end

  test "exchange rates reject a provider from another concept" do
    ClimateControl.modify("EXCHANGE_RATE_PROVIDER" => "openai") do
      check = ConfigurationHealth.new.exchange_rates
      assert_equal :incomplete, check.status
      assert_equal :unknown, check.providers.first.key
    end
  end

  test "blank exchange rate selection is not configured" do
    Setting.stubs(:exchange_rate_provider).returns(nil)

    ClimateControl.modify("EXCHANGE_RATE_PROVIDER" => nil) do
      assert_equal :not_configured, ConfigurationHealth.new.exchange_rates.status
    end
  end

  test "local storage is configured without cloud credentials or filesystem access" do
    stub_storage("local", { service: "Disk", root: "/private/storage/root" })
    File.expects(:writable?).never

    check = ConfigurationHealth.new.storage
    assert_equal :configured, check.status
    assert_equal :local, check.backend
    assert_empty check.issues
    assert_no_match(%r{/private/storage}, check.inspect)
  end

  test "cloud storage settings are checked without constructing a storage client" do
    stub_storage("amazon", {
      service: "S3", region: "us-east-1", bucket: "private-bucket",
      access_key_id: "private-access-key", secret_access_key: "private-secret-key"
    })
    ActiveStorage::Service.expects(:configure).never

    check = ConfigurationHealth.new.storage
    assert_equal :configured, check.status
    assert_equal :amazon, check.backend
    assert_no_match(/private-/, check.inspect)
  end

  test "cloud role credentials are unverified rather than missing" do
    stub_storage("amazon", { service: "S3", region: "us-east-1", bucket: "private-bucket" })
    assert_equal :not_checked, ConfigurationHealth.new.storage.status

    stub_storage("google", { service: "GCS", bucket: "private-bucket" })
    assert_equal :not_checked, ConfigurationHealth.new.storage.status
  end

  test "incomplete cloud storage shows only missing field names" do
    stub_storage("generic_s3", { service: "S3", access_key_id: "private-key" })

    check = ConfigurationHealth.new.storage
    assert_equal :incomplete, check.status
    assert_equal [ :bucket, :region, :credentials, :endpoint ], check.issues
    assert_no_match(/private-key/, check.inspect)
  end

  test "R2 with no account ID is incomplete despite the interpolated endpoint" do
    stub_storage("cloudflare", {
      service: "S3", region: "auto", bucket: "bucket",
      endpoint: "https://.r2.cloudflarestorage.com", access_key_id: "key", secret_access_key: "secret"
    })

    check = ConfigurationHealth.new.storage
    assert_equal :incomplete, check.status
    assert_equal [ :endpoint ], check.issues
  end

  test "missing selected storage configuration is not configured and name is sanitized" do
    Rails.application.config.active_storage.stubs(:service).returns(:unexpected_secret)
    Rails.application.config.active_storage.stubs(:service_configurations).returns({})

    check = ConfigurationHealth.new.storage
    assert_equal :not_configured, check.status
    assert_equal :other, check.backend
    assert_no_match(/unexpected_secret/, check.inspect)
  end

  test "custom storage is left unverified" do
    stub_storage("custom", { service: "OtherStorage" })

    check = ConfigurationHealth.new.storage
    assert_equal :not_checked, check.status
    assert_equal :other, check.backend
  end

  test "a standard storage name with a custom adapter is not misreported" do
    stub_storage("local", { service: "OtherStorage" })

    check = ConfigurationHealth.new.storage
    assert_equal :not_checked, check.status
    assert_equal :other, check.backend
  end

  private
    def stub_storage(name, settings)
      Rails.application.config.active_storage.stubs(:service).returns(name.to_sym)
      Rails.application.config.active_storage.stubs(:service_configurations).returns({ name => settings })
    end
end
