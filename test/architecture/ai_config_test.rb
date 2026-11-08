require "test_helper"

# The deprecated ENV path resolves every supported setup to the routes the code not yet on the
# router would use, so moving a feature onto the router changes nothing unless it means to.
class AiConfigTest < ActiveSupport::TestCase
  include AiLegacySetups

  LLM_FEATURES = Ai::LegacyEnvConfig::LLM_FEATURES
  ENDPOINTS_BY_PROVIDER = { Provider::Openai => %w[openai openai_compatible], Provider::Anthropic => %w[anthropic] }.freeze

  setup do
    @family = families(:dylan_family)
    @user = users(:family_admin)   # AI switch on
  end

  SETUPS.each_key do |id|
    test "#{id}: every non-chat feature's first route is today's provider and model" do
      in_ai_setup(id, family: @family) do
        today = Provider::Registry.preferred_llm_provider
        LLM_FEATURES.each { |feature| assert_same_route(today, Ai.plan(feature, family: @family, user: @user), "#{id} #{feature}") }

        assert_same_route(jev_chosen? ? :jev : today, Ai.plan(:categorize, family: @family), "#{id} categorize")
        assert_operator Ai::Config.current.routes_for(:categorize).size, :<=, 1, "#{id} categorize lists one model"
        LLM_FEATURES.each { |feature| assert_operator Ai::Config.current.routes_for(feature).size, :<=, 1, "#{id} #{feature} lists one model" }
      end
    end
  end

  # The instance's choice: Jev for every family when it's chosen and reachable,
  # the preferred LLM otherwise, and the shadow route runs the other one.
  test "the instance's Jev choice categorizes every family on Jev, shadowed by the preferred LLM" do
    in_ai_setup("M1", family: @family) do
      [ @family, families(:empty) ].each do |family|
        assert_equal "jev", Ai.plan(:categorize, family:).route.endpoint.name
        assert_same_route(Provider::Registry.preferred_llm_provider, Ai.plan(:shadow_categorize, family:), "M1 shadow_categorize")
      end
    end

    in_ai_setup("C2", family: @family) do
      assert_nil Ai.plan(:shadow_categorize, family: @family), "no Jev key: nothing to compare with"
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
    # The instance chose Jev and it has a key, at the default (reachable) endpoint.
    def jev_chosen?
      Ai::LegacyEnvConfig.categorization_provider == "jev" && Ai::LegacyEnvConfig::Jev.configured?
    end

    def assert_same_route(provider, plan, message)
      if provider.nil?
        assert_nil plan, "#{message}: today nothing runs, the router planned #{plan&.route.inspect}"
        return
      end

      assert plan, "#{message}: today #{provider.class.name} runs, the router has no route"
      if provider == :jev
        assert_equal [ "jev", Ai::LegacyEnvConfig::Jev.effective_model ], [ plan.route.endpoint.name, plan.model.name ], message
        return
      end

      assert_includes ENDPOINTS_BY_PROVIDER.fetch(provider.class), plan.route.endpoint.name, message
      assert_equal provider.instance_variable_get(:@default_model), plan.model.name, message
    end
end
