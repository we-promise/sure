require "test_helper"

# The deprecated ENV path resolves every setup today's code supports to the routes today's code
# would use (ai-plumbing-redesign.md, section 17), so moving a feature onto the router changes
# nothing until a PR means it to. PR 7 adds the halves for the tables, the config file and
# ai:export_config.
class AiConfigTest < ActiveSupport::TestCase
  include AiLegacySetups

  LLM_FEATURES = Ai::LegacyEnvConfig::LLM_FEATURES
  ENDPOINTS_BY_PROVIDER = { Provider::Openai => %w[openai openai_compatible], Provider::Anthropic => %w[anthropic], Provider::Jev => %w[jev] }.freeze

  setup do
    @family = families(:dylan_family)
    @family.update!(categorization_provider: "llm")
    @user = users(:family_admin)   # AI switch on
  end

  SETUPS.each_key do |id|
    test "#{id}: every non-chat feature's first route is today's provider and model" do
      in_ai_setup(id, family: @family) do
        today = Provider::Registry.preferred_llm_provider
        LLM_FEATURES.each { |feature| assert_same_route(today, Ai.plan(feature, family: @family, user: @user), "#{id} #{feature}") }

        assert_same_route(jev_for(@family) || today, Ai.plan(:categorize, family: @family), "#{id} categorize")
        LLM_FEATURES.each { |feature| assert_operator Ai::Config.current.routes_for(feature).size, :<=, 1, "#{id} #{feature} lists one model" }
      end
    end
  end

  # Today's family-level rule (Family#resolved_categorization_provider until 2c): Jev for families
  # that chose it, when it can be built; the preferred LLM otherwise.
  test "a family that chose Jev categorizes on Jev; another on the preferred LLM" do
    jev_family = families(:empty)
    jev_family.update!(categorization_provider: "jev")

    in_ai_setup("M1", family: jev_family) do
      assert_equal "jev", Ai.plan(:categorize, family: jev_family).route.endpoint.name
      assert_same_route(Provider::Registry.preferred_llm_provider, Ai.plan(:categorize, family: @family), "M1 categorize")
    end
  end

  test "Settings-only installs get the same embedding server as their LLM (drift bug 5)" do
    VectorStore::Pgvector.stubs(:available?).returns(true)

    in_ai_setup("M3", family: @family) do
      with_env_overrides("VECTOR_STORE_PROVIDER" => "pgvector") do
        assert_equal "https://gateway.example.test/v1", VectorStore.embedding_uri_base
        assert_equal "sk-setting", VectorStore.embedding_access_token
      end
    end
  end

  test "the web and a worker build the same snapshot from the same ENV and settings" do
    in_ai_setup("M2", family: @family) do
      first = Ai::LegacyEnvConfig.build
      second = Ai::LegacyEnvConfig.build

      assert_equal first.endpoints, second.endpoints
      assert_equal first.routes, second.routes
    end
  end

  private
    # Jev, for a family that chose it, when it can be built: today's resolution.
    def jev_for(family)
      return unless family.effective_categorization_provider == "jev"

      Provider::Registry.get_provider(:jev)
    rescue Provider::Error
      nil
    end

    def assert_same_route(provider, plan, message)
      if provider.nil?
        assert_nil plan, "#{message}: today nothing runs, the router planned #{plan&.route.inspect}"
        return
      end

      assert plan, "#{message}: today #{provider.class.name} runs, the router has no route"
      assert_includes ENDPOINTS_BY_PROVIDER.fetch(provider.class), plan.route.endpoint.name, message
      assert_equal provider.instance_variable_get(:@default_model), plan.model.name, message
    end
end
