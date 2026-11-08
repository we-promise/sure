require "test_helper"

class Provider::RegistryTest < ActiveSupport::TestCase
  test "providers filters out nil values when provider is not configured" do
    # Ensure no LLM provider is configured
    ClimateControl.modify(
      "OPENAI_ACCESS_TOKEN" => nil,
      "ANTHROPIC_ACCESS_TOKEN" => nil,
      "ANTHROPIC_API_KEY" => nil
    ) do
      Setting.stubs(:openai_access_token).returns(nil)
      Setting.stubs(:anthropic_access_token).returns(nil)

      registry = Provider::Registry.for_concept(:llm)

      # Should return empty array instead of [nil]
      assert_equal [], registry.providers
    end
  end

  test "providers returns configured providers" do
    # Mock a configured OpenAI provider
    mock_provider = mock("openai_provider")
    Provider::Registry.stubs(:openai).returns(mock_provider)

    registry = Provider::Registry.for_concept(:llm)

    assert_equal [ mock_provider ], registry.providers
  end

  test "get_provider raises error when provider not found for concept" do
    registry = Provider::Registry.for_concept(:llm)

    error = assert_raises(Provider::Registry::Error) do
      registry.get_provider(:nonexistent)
    end

    assert_match(/Provider 'nonexistent' not found for concept: llm/, error.message)
  end

  test "get_provider returns nil when provider not configured" do
    # Ensure OpenAI is not configured
    ClimateControl.modify("OPENAI_ACCESS_TOKEN" => nil) do
      Setting.stubs(:openai_access_token).returns(nil)

      registry = Provider::Registry.for_concept(:llm)

      # Should return nil when provider method exists but returns nil
      assert_nil registry.get_provider(:openai)
    end
  end

  test "anthropic provider returns nil when no credentials are configured" do
    ClimateControl.modify(
      "ANTHROPIC_ACCESS_TOKEN" => nil,
      "ANTHROPIC_API_KEY" => nil
    ) do
      Setting.stubs(:anthropic_access_token).returns(nil)

      assert_nil Provider::Registry.get_provider(:anthropic)
    end
  end

  test "anthropic provider initializes from ANTHROPIC_API_KEY env" do
    ClimateControl.modify("ANTHROPIC_API_KEY" => "fake-anthropic-key-for-tests", "ANTHROPIC_ACCESS_TOKEN" => nil) do
      Setting.stubs(:anthropic_access_token).returns(nil)

      provider = Provider::Registry.get_provider(:anthropic)

      assert_instance_of Provider::Anthropic, provider
    end
  end

  test "anthropic provider falls back to Setting when ENV is empty" do
    ClimateControl.modify(
      "ANTHROPIC_ACCESS_TOKEN" => "",
      "ANTHROPIC_API_KEY" => "",
      "ANTHROPIC_BASE_URL" => "",
      "ANTHROPIC_MODEL" => ""
    ) do
      Setting.stubs(:anthropic_access_token).returns("fake-anthropic-key-from-setting")
      Setting.stubs(:anthropic_base_url).returns(nil)
      Setting.stubs(:anthropic_model).returns(nil)

      provider = Provider::Registry.get_provider(:anthropic)

      assert_instance_of Provider::Anthropic, provider
    end
  end

  test "openai provider falls back to Setting when ENV is empty string" do
    # Mock ENV to return empty string (common in Docker/env files)
    # Use stub_env helper which properly stubs ENV access
    ClimateControl.modify(
      "OPENAI_ACCESS_TOKEN" => "",
      "OPENAI_URI_BASE" => "",
      "OPENAI_MODEL" => ""
    ) do
      Setting.stubs(:openai_access_token).returns("test-token-from-setting")
      Setting.stubs(:openai_uri_base).returns(nil)
      Setting.stubs(:openai_model).returns(nil)

      provider = Provider::Registry.get_provider(:openai)

      # Should successfully create provider using Setting value
      assert_not_nil provider
      assert_instance_of Provider::Openai, provider
    end
  end

  test "preferred_llm_provider returns openai by default" do
    openai = mock("openai")
    Provider::Registry.stubs(:openai).returns(openai)
    Provider::Registry.stubs(:anthropic).returns(mock("anthropic"))
    Setting.stubs(:llm_provider).returns("openai")

    assert_same openai, Provider::Registry.preferred_llm_provider
  end

  test "preferred_llm_provider returns anthropic when selected" do
    anthropic = mock("anthropic")
    Provider::Registry.stubs(:openai).returns(mock("openai"))
    Provider::Registry.stubs(:anthropic).returns(anthropic)
    Setting.stubs(:llm_provider).returns("anthropic")

    assert_same anthropic, Provider::Registry.preferred_llm_provider
  end

  test "preferred_llm_provider falls back to the configured provider when the selected one is unconfigured" do
    openai = mock("openai")
    Provider::Registry.stubs(:openai).returns(openai)
    Provider::Registry.stubs(:anthropic).returns(nil)
    Setting.stubs(:llm_provider).returns("anthropic")

    assert_same openai, Provider::Registry.preferred_llm_provider
  end

  test "preferred_llm_provider follows LLM_PROVIDER over a stored choice" do
    original = Setting.raw_llm_provider
    Setting.llm_provider = "openai"
    anthropic = mock("anthropic")
    Provider::Registry.stubs(:openai).returns(mock("openai"))
    Provider::Registry.stubs(:anthropic).returns(anthropic)

    with_env_overrides("LLM_PROVIDER" => "anthropic") do
      assert_same anthropic, Provider::Registry.preferred_llm_provider
    end
  ensure
    Setting.llm_provider = original
  end

  test "preferred_llm_provider returns nil when no provider is configured" do
    Provider::Registry.stubs(:openai).returns(nil)
    Provider::Registry.stubs(:anthropic).returns(nil)
    Setting.stubs(:llm_provider).returns("openai")

    assert_nil Provider::Registry.preferred_llm_provider
  end

  test "family provider selection is isolated from other families and installation defaults" do
    family = families(:dylan_family)
    other_family = families(:empty)
    family.create_ai_configuration!(provider: "anthropic", api_key: "synthetic-family-a-key")
    other_family.create_ai_configuration!(provider: "openai", api_key: "synthetic-family-b-key")
    family_provider = mock("family A provider")
    other_provider = mock("family B provider")
    Provider::Anthropic.expects(:new).with(
      "synthetic-family-a-key", model: Provider::Anthropic::DEFAULT_MODEL, use_global_settings: false
    ).returns(family_provider)
    Provider::Openai.expects(:new).with(
      "synthetic-family-b-key", model: Provider::Openai::DEFAULT_MODEL, use_global_settings: false
    ).returns(other_provider)
    Provider::Registry.expects(:openai).never
    Provider::Registry.expects(:anthropic).never

    assert_same family_provider, Provider::Registry.preferred_llm_provider(family: family)
    assert_same other_provider, Provider::Registry.get_provider(:openai, family: other_family)
    assert_nil Provider::Registry.get_provider(:openai, family: family)
    assert_equal [ :anthropic ], Provider::Registry.llm_provider_order(family: family)
    assert_equal Provider::Anthropic::DEFAULT_MODEL, Provider::Registry.default_llm_model(family: family)
  end

  test "families without an override retain installation provider fallback" do
    family = families(:dylan_family)
    openai = mock("installation provider")
    Provider::Registry.stubs(:openai).returns(openai)
    Provider::Registry.stubs(:anthropic).returns(nil)
    Setting.stubs(:llm_provider).returns("anthropic")

    assert_same openai, Provider::Registry.preferred_llm_provider(family: family)
    assert_same openai, Provider::Registry.get_provider(:openai, family: family)
  end

  test "an unreadable family override does not fall back to global or alternate providers" do
    family = families(:dylan_family)
    configuration = family.create_ai_configuration!(provider: "anthropic", api_key: "synthetic-key")
    configuration.update_column(:encrypted_api_key, "corrupt-ciphertext")
    Provider::Registry.expects(:openai).never
    Provider::Registry.expects(:anthropic).never

    assert_nil Provider::Registry.preferred_llm_provider(family: family)
    assert_nil Provider::Registry.get_provider(:openai, family: family)
    assert_equal [], Provider::Registry.for_concept(:llm, family: family).providers
    assert_equal Provider::Anthropic::DEFAULT_MODEL, Provider::Registry.default_llm_model(family: family)
  end

  test "concept registries preserve the family for individual and available providers" do
    family = families(:dylan_family)
    family.create_ai_configuration!(provider: "anthropic", api_key: "synthetic-key")
    provider = mock("family provider")
    Provider::Anthropic.stubs(:new).with(
      "synthetic-key", model: Provider::Anthropic::DEFAULT_MODEL, use_global_settings: false
    ).returns(provider)
    registry = Provider::Registry.for_concept(:llm, family: family)

    assert_equal [ provider ], registry.providers
    assert_same provider, registry.get_provider(:anthropic)
    assert_nil registry.get_provider(:openai)
  end

  test "OpenRouter belongs only to the explicitly configured family" do
    family = families(:dylan_family)
    family.create_ai_configuration!(provider: "openrouter", model: "openai/gpt-4.1-mini", api_key: "synthetic-router-key")
    Provider::Registry.expects(:openai).never
    Provider::Registry.expects(:anthropic).never
    registry = Provider::Registry.for_concept(:llm, family: family)

    assert_equal [ Provider::Openrouter ], registry.providers.map(&:class)
    assert_instance_of Provider::Openrouter, registry.get_provider(:openrouter)
    assert_nil registry.get_provider(:openai)
    assert_nil registry.get_provider(:anthropic)
    assert_nil Provider::Registry.get_provider(:openrouter, family: families(:empty))
    assert_equal [ :openrouter ], Provider::Registry.llm_provider_order(family: family)
    assert_equal "openai/gpt-4.1-mini", Provider::Registry.default_llm_model(family: family)
    assert_equal %i[openai anthropic], Provider::Registry.for_concept(:llm).provider_keys
  end

  test "a cached missing configuration does not hide a newly saved family override" do
    family = families(:dylan_family)
    registry = Provider::Registry.for_concept(:llm, family: family)
    assert_nil family.ai_configuration
    assert_equal %i[openai anthropic], registry.provider_keys

    Family.find(family.id).create_ai_configuration!(
      provider: "openrouter", model: "openai/gpt-4.1-mini", api_key: "synthetic-new-key"
    )
    provider = mock("new family provider")
    Provider::Openrouter.stubs(:new).with("synthetic-new-key", model: "openai/gpt-4.1-mini").returns(provider)
    Provider::Registry.expects(:openai).never
    Provider::Registry.expects(:anthropic).never

    assert_same provider, Provider::Registry.preferred_llm_provider(family: family)
    assert_same provider, Provider::Registry.get_provider(:openrouter, family: family)
    assert_equal [ :openrouter ], Provider::Registry.llm_provider_order(family: family)
    assert_equal "openai/gpt-4.1-mini", Provider::Registry.default_llm_model(family: family)
    assert_equal Family::AiConfiguration::PROVIDERS.map(&:to_sym), registry.provider_keys
    assert_same provider, registry.get_provider(:openrouter)
    assert_equal [ provider ], registry.providers
    assert_nil registry.get_provider(:openai)
  end

  test "new selections use rotated credentials without changing an existing provider" do
    family = families(:dylan_family)
    family.create_ai_configuration!(provider: "openai", api_key: "synthetic-old-key")
    cached_configuration = family.ai_configuration
    registry = Provider::Registry.for_concept(:llm, family: family)
    old_provider = OpenStruct.new(default_model: Provider::Openai::DEFAULT_MODEL)
    new_provider = mock("rotated family provider")
    Provider::Openai.expects(:new).with(
      "synthetic-old-key", model: Provider::Openai::DEFAULT_MODEL, use_global_settings: false
    ).returns(old_provider)
    Provider::Openai.stubs(:new).with(
      "synthetic-rotated-key", model: "gpt-4.1-mini", use_global_settings: false
    ).returns(new_provider)
    Provider::Registry.expects(:openai).never
    Provider::Registry.expects(:anthropic).never
    selected_provider = Provider::Registry.preferred_llm_provider(family: family)

    Family.find(family.id).ai_configuration.update!(api_key: "synthetic-rotated-key", model: "gpt-4.1-mini")

    assert_same new_provider, Provider::Registry.preferred_llm_provider(family: family)
    assert_same new_provider, Provider::Registry.get_provider(:openai, family: family)
    assert_same new_provider, registry.get_provider(:openai)
    assert_equal [ new_provider ], registry.providers
    assert_equal "gpt-4.1-mini", Provider::Registry.default_llm_model(family: family)
    assert_same old_provider, selected_provider
    assert_equal Provider::Openai::DEFAULT_MODEL, selected_provider.default_model
    assert_equal "synthetic-old-key", cached_configuration.api_key
  end

  test "retained families and registries observe provider switches" do
    family = families(:dylan_family)
    family.create_ai_configuration!(provider: "anthropic", api_key: "synthetic-old-key")
    assert_equal "anthropic", family.ai_configuration.provider
    registry = Provider::Registry.for_concept(:llm, family: family)

    Family.find(family.id).ai_configuration.update!(
      provider: "openrouter", model: "openai/gpt-4.1-mini", api_key: "synthetic-router-key"
    )
    provider = mock("switched family provider")
    Provider::Openrouter.stubs(:new).with("synthetic-router-key", model: "openai/gpt-4.1-mini").returns(provider)
    Provider::Anthropic.expects(:new).never
    Provider::Registry.expects(:openai).never
    Provider::Registry.expects(:anthropic).never

    assert_same provider, Provider::Registry.preferred_llm_provider(family: family)
    assert_same provider, Provider::Registry.get_provider(:openrouter, family: family)
    assert_nil Provider::Registry.get_provider(:anthropic, family: family)
    assert_equal [ :openrouter ], Provider::Registry.llm_provider_order(family: family)
    assert_equal "openai/gpt-4.1-mini", Provider::Registry.default_llm_model(family: family)
    assert_same provider, registry.get_provider(:openrouter)
    assert_nil registry.get_provider(:anthropic)
    assert_equal [ provider ], registry.providers
  end

  test "a newly corrupted override does not reuse cached or installation credentials" do
    family = families(:dylan_family)
    family.create_ai_configuration!(provider: "openai", api_key: "synthetic-cached-key")
    assert_equal "synthetic-cached-key", family.ai_configuration.api_key
    registry = Provider::Registry.for_concept(:llm, family: family)
    Family.find(family.id).ai_configuration.update_column(:encrypted_api_key, "corrupt-ciphertext")
    Provider::Openai.expects(:new).never
    Provider::Registry.expects(:openai).never
    Provider::Registry.expects(:anthropic).never

    assert_nil Provider::Registry.preferred_llm_provider(family: family)
    assert_nil Provider::Registry.get_provider(:openai, family: family)
    assert_nil registry.get_provider(:openai)
    assert_equal [], registry.providers
    assert_equal [ :openai ], Provider::Registry.llm_provider_order(family: family)
    assert_equal Provider::Openai::DEFAULT_MODEL, Provider::Registry.default_llm_model(family: family)
  end

  test "provider collections retain one snapshot when the provider changes during construction" do
    family = families(:dylan_family)
    family.create_ai_configuration!(provider: "openai", api_key: "synthetic-original-key")
    registry = Provider::Registry.for_concept(:llm, family: family)
    writer = Family.find(family.id).ai_configuration
    original_provider = mock("original provider")
    replacement_provider = mock("replacement provider")
    Provider::Anthropic.stubs(:new).with(
      "synthetic-replacement-key", model: Provider::Anthropic::DEFAULT_MODEL, use_global_settings: false
    ).returns(replacement_provider)
    Provider::Registry.expects(:openai).never
    Provider::Registry.expects(:anthropic).never

    switch_during_construction = lambda do |access_token, **options|
      assert_equal "synthetic-original-key", access_token
      assert_equal({ model: Provider::Openai::DEFAULT_MODEL, use_global_settings: false }, options)
      writer.update!(provider: "anthropic", model: Provider::Anthropic::DEFAULT_MODEL, api_key: "synthetic-replacement-key")
      original_provider
    end

    Provider::Openai.stub(:new, switch_during_construction) do
      assert_equal [ original_provider ], registry.providers
    end
    assert_equal [ replacement_provider ], registry.providers
  end

  test "each family selection reads one uncached configuration snapshot" do
    family = families(:dylan_family)
    family.create_ai_configuration!(provider: "openai", api_key: "synthetic-key")
    Provider::Openai.stubs(:new).returns(mock("family provider"))
    registry = Provider::Registry.for_concept(:llm, family: family)
    selections = [
      -> { Provider::Registry.get_provider(:openai, family: family) },
      -> { Provider::Registry.preferred_llm_provider(family: family) },
      -> { Provider::Registry.llm_provider_order(family: family) },
      -> { Provider::Registry.default_llm_model(family: family) },
      -> { registry.get_provider(:openai) },
      -> { registry.provider_keys },
      -> { registry.providers }
    ]

    Family::AiConfiguration.cache do
      Family::AiConfiguration.find_by(family_id: family.id)
      selections.each do |selection|
        queries = capture_sql_queries { selection.call }
        configuration_reads = queries.grep(/\ASELECT\b.*FROM "family_ai_configurations"/)
        assert_equal 1, configuration_reads.size
      end
    end
  end

  test "an unreadable OpenRouter credential never falls back to global providers" do
    family = families(:dylan_family)
    family.create_ai_configuration!(provider: "openrouter", model: "openai/gpt-4.1-mini", api_key: "synthetic-key")
    family.ai_configuration.update_column(:encrypted_api_key, "corrupt-ciphertext")
    Provider::Registry.expects(:openai).never
    Provider::Registry.expects(:anthropic).never

    assert_nil Provider::Registry.preferred_llm_provider(family: family)
    assert_equal [], Provider::Registry.for_concept(:llm, family: family).providers
  end
end
