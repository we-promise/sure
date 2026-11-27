require "test_helper"

# The escalation checks that don't need a sequencer:
# failover marks the smallest broken thing and moves down the list, escalation moves on without
# a mark, and other refusals aren't retried.
class AiEscalationTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @cache = ActiveSupport::Cache::MemoryStore.new
    Rails.stubs(:cache).returns(@cache)

    openai = AiTestHelper.test_config.endpoint(:openai)
    gpu = AiTestHelper.test_config.endpoint(:gpu)
    gpu_sibling = gpu.with(name: "gpu_large")   # another endpoint row on the same server
    gateway = ai_endpoint(name: "gateway", base_url: "https://gateway.example.test/v1")
    capabilities = %i[structured_output]
    models = [
      ai_model(endpoint: gpu, name: "qwen3-3b", capabilities:), ai_model(endpoint: gpu, name: "qwen3-20b", capabilities:),
      ai_model(endpoint: gpu_sibling, name: "qwen3-32b", capabilities:),
      ai_model(endpoint: gateway, name: "vendor-a/model", capabilities:), ai_model(endpoint: gateway, name: "vendor-b/model", capabilities:),
      ai_model(endpoint: openai, name: "gpt-4.1-mini", capabilities:)
    ]
    @models = models.index_by { "#{_1.endpoint.name}/#{_1.name}" }
  end

  def route_through(*names, &block)
    Ai::Config.with(AiTestHelper.build_ai_config(@models.values, { detect_merchants: names }), &block)
  end

  def generate = AiTestGeneration.new(transactions: [ { id: "t1", description: "AMZN", merchant: nil } ], family: @family).call

  def served_by(request) = "#{request.model.endpoint.name}/#{request.model.name}"

  test "a refused connection marks the server, so its other endpoint rows are skipped too" do
    route_through("gpu/qwen3-3b", "gpu_large/qwen3-32b", "openai/gpt-4.1-mini") do
      requests = stub_ai { _1.model.endpoint.local? ? raise(Ai::Error::Unreachable, "refused") : AiTestGeneration.answer(_1) }

      first = generate
      second = generate

      assert_equal "openai", first.route.endpoint.name
      assert_equal %w[gpu/qwen3-3b openai/gpt-4.1-mini openai/gpt-4.1-mini], requests.map { served_by(_1) }
      assert_equal "openai", second.route.endpoint.name
    end
  end

  test "a cloud gateway's 503 or 429 marks only that model; the next model on the gateway answers" do
    route_through("gateway/vendor-a/model", "gateway/vendor-b/model") do
      requests = stub_ai { served_by(_1) == "gateway/vendor-a/model" ? raise(Ai::Error::RateLimited, "429") : AiTestGeneration.answer(_1) }

      assert_equal "vendor-b/model", generate.route.model.name
      assert_equal "vendor-b/model", generate.route.model.name
      assert_equal %w[gateway/vendor-a/model gateway/vendor-b/model gateway/vendor-b/model], requests.map { served_by(_1) }
    end
  end

  test "a 401 or a spent balance marks only the key that got it" do
    route = Ai::Route.new(feature: :detect_merchants, model: @models["gateway/vendor-a/model"])

    key = Ai::DownMarks.key_for(route, Ai::Error::Unauthorized.new("401"))
    assert_match %r{\Aai/down/key/gateway/\h{12}\z}, key
    assert_equal key, Ai::DownMarks.key_for(route, Ai::Error::NoCredit.new("402"))
    assert_not_includes key, route.endpoint.api_key.to_s
    replaced = route.with(model: route.model.with(endpoint: route.endpoint.with(api_key: "a-new-key")))
    assert_not_equal key, Ai::DownMarks.key_for(replaced, Ai::Error::Unauthorized.new("401")), "a replaced key isn't marked down"
    assert_match %r{\Aai/down/model/gateway/\h{12}/vendor-a/model\z}, Ai::DownMarks.key_for(route, Ai::Error::ModelMissing.new("404"))
  end

  test "down marks expire after 60 seconds" do
    route_through("gpu/qwen3-3b", "openai/gpt-4.1-mini") do
      stub_ai { _1.model.endpoint.local? ? raise(Ai::Error::Unreachable, "refused") : AiTestGeneration.answer(_1) }
      generate

      travel 61.seconds do
        requests = stub_ai { AiTestGeneration.answer(_1) }
        assert_equal "gpu", generate.route.endpoint.name
        assert_equal 1, requests.size
      end
    end
  end
end
