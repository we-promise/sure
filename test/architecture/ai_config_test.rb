require "test_helper"

# The deprecated ENV path resolves every supported setup to the routes the code not yet on the
# router would use, so moving a feature onto the router changes nothing unless it means to.
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

        assert_same_route(@family.resolved_categorization_provider, Ai.plan(:categorize, family: @family), "#{id} categorize")
      end
    end
  end

  test "Settings-only installs get the same embedding server as their LLM" do
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
    def assert_same_route(provider, plan, message)
      if provider.nil?
        assert_nil plan, "#{message}: today nothing runs, the router planned #{plan&.route.inspect}"
        return
      end

      assert plan, "#{message}: today #{provider.class.name} runs, the router has no route"
      assert_includes ENDPOINTS_BY_PROVIDER.fetch(provider.class), plan.route.endpoint.name, message
      assert_equal provider.default_model, plan.model.name, message
    end
end
