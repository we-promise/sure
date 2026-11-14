require "test_helper"

# `embed` against a real embedding server: venus's llama.cpp embedding instance,
# granite-embedding-small-english-r2 (384 dimensions), as the spike's embed_test was. Replayed
# from test/vcr_cassettes/ai/llama_cpp/, recorded with RECORD_CASSETTES=1 and LLAMA_CPP_API_KEY
# set, or run live with AI_LIVE=1. With neither, it's skipped, saying so.
class AiEmbedLiveTest < ActiveSupport::TestCase
  KEY = "LLAMA_CPP_API_KEY".freeze
  BASE_URL = ENV.fetch("EMBED_LIVE_BASE_URL", "http://10.72.200.61:8181/v1")
  MODEL = ENV.fetch("EMBED_LIVE_MODEL", "granite-embedding-small-english-r2")
  DIMENSIONS = Integer(ENV.fetch("EMBED_LIVE_DIMENSIONS", "384"))

  setup do
    @family = families(:dylan_family)
  end

  test "llama.cpp: a vector per text, with the model's dimensions, and a usage row" do
    skip "no cassette ai/llama_cpp/embed_texts; record with RECORD_CASSETTES=1 and #{KEY} set" unless ai_cassette_available?("llama_cpp", "embed_texts", key: KEY)

    endpoint = Ai::Config::Endpoint.new(name: "embed", protocol: :compatible, base_url: BASE_URL, api_key: ENV[KEY].presence || "recorded",
                                        location: :local, timeout_seconds: 60)
    model = Ai::Config::Model.new(endpoint:, name: MODEL, capabilities: %i[embedding], embedding_dimensions: DIMENSIONS)
    request = Ai::Transport::Base::EmbedRequest.new(feature: :embed, family: @family, model:,
                                                    texts: [ "Monthly apartment rent payment", "Payroll preauthorized credit" ])

    response = with_ai_cassette("llama_cpp", "embed_texts") { Ai::Transport.for(endpoint).embed(request) }

    assert_equal 2, response.vectors.size
    assert_equal [ DIMENSIONS ], response.vectors.map(&:size).uniq
    assert_not_equal response.vectors.first, response.vectors.last
    assert_equal 1, @family.llm_usages.where(operation: "embed").count
  end
end
