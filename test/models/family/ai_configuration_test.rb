require "test_helper"

class Family::AiConfigurationTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @other_family = families(:empty)
  end

  test "credentials are encrypted even without optional Active Record encryption" do
    ActiveRecordEncryptionConfig.stubs(:explicitly_configured?).returns(false)
    configuration = create_configuration

    assert_equal "synthetic-family-key", configuration.reload.api_key
    assert_not_includes configuration.encrypted_api_key, "synthetic-family-key"
    assert_equal Provider::Openai::DEFAULT_MODEL, configuration.model
  end

  test "ciphertext cannot be transplanted to another family or treated as plaintext" do
    configuration = create_configuration
    copied = Family::AiConfiguration.new(family: @other_family, provider: "openai", encrypted_api_key: configuration.encrypted_api_key)

    assert_raises(Family::AiConfiguration::InvalidCredential) { copied.api_key }
    assert_nil copied.provider_instance

    configuration.encrypted_api_key = "legacy-plaintext-must-not-work"
    assert_raises(Family::AiConfiguration::InvalidCredential) { configuration.api_key }
    assert_nil configuration.provider_instance
  end

  test "plain and encrypted credentials never appear in inspection or serialization" do
    configuration = create_configuration
    output = [
      configuration.inspect,
      configuration.to_json,
      configuration.to_json(methods: :api_key),
      configuration.to_json(only: :encrypted_api_key),
      @family.reload.to_json(include: :ai_configuration)
    ].join

    assert_not_includes output, "synthetic-family-key"
    assert_not_includes output, configuration.encrypted_api_key
    assert_match(/encrypted_api_key: "\[FILTERED\]"/, configuration.inspect)
  end

  test "financial exports contain neither credentials nor their ciphertext" do
    configuration = create_configuration
    export = Family::DataExporter.new(@family).generate_export

    Zip::File.open_buffer(export) do |zip|
      zip.entries.each do |entry|
        content = entry.get_input_stream.read
        assert_not_includes content, configuration.api_key
        assert_not_includes content, configuration.encrypted_api_key
      end
    end
  end

  test "provider construction receives only family credentials and official defaults" do
    configuration = create_configuration
    expected = mock("family provider")
    Provider::Openai.expects(:new).with(
      "synthetic-family-key", model: Provider::Openai::DEFAULT_MODEL, use_global_settings: false
    ).returns(expected)

    assert_same expected, configuration.provider_instance
    assert_nil configuration.provider_instance(:anthropic)
  end

  test "a missing credential leaves the override unavailable" do
    configuration = create_configuration
    configuration.encrypted_api_key = nil

    assert_nil configuration.provider_instance
    assert_not configuration.valid?
  end

  test "OpenRouter requires a selected model and constructs only its family provider" do
    configuration = @family.build_ai_configuration(provider: "openrouter", api_key: "synthetic-router-key")
    assert_not configuration.valid?
    assert_nil configuration.provider_instance
    configuration.model = "anthropic/claude-sonnet-4"
    configuration.save!

    provider = configuration.provider_instance
    assert_instance_of Provider::Openrouter, provider
    assert_equal "anthropic/claude-sonnet-4", provider.default_model
    assert_nil configuration.provider_instance(:anthropic)
    assert_nil configuration.provider_instance(:openai)
    assert_not_includes configuration.to_json, "synthetic-router-key"
  end

  private
    def create_configuration
      @family.create_ai_configuration!(provider: "openai", api_key: "synthetic-family-key")
    end
end
