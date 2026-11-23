require "test_helper"

# `ocr` against real servers: Mistral and Cohere through RubyLLM.ocr, and a
# local OCR model through chat, on the spike's scanned sample statement. Mistral and Cohere are
# untested live until someone records these with a key: replayed from
# test/vcr_cassettes/ai/{mistral,cohere,llama_cpp}/, recorded with RECORD_CASSETTES=1 and the key
# set, or run live with AI_LIVE=1. With neither, each is skipped, saying so.
class AiOcrLiveTest < ActiveSupport::TestCase
  SERVERS = {
    mistral: { key: "MISTRAL_LIVE_API_KEY", model: ENV.fetch("MISTRAL_LIVE_OCR_MODEL", "mistral-ocr-latest"), preset: :mistral },
    cohere: { key: "COHERE_LIVE_API_KEY", model: ENV.fetch("COHERE_LIVE_OCR_MODEL", "parse-v5.0"), preset: :cohere },
    # OCR_LIVE_MODEL changes the model for live and recording runs; a replay asks for the recorded one.
    llama_cpp: { key: "LLAMA_CPP_API_KEY", model: (AiTestHelper.live_or_recording? && ENV["OCR_LIVE_MODEL"].presence) || "unlimited-ocr-2",
                 preset: nil, base_url: AiTestHelper::LLAMA_CPP_URL, ocr_prompt: "unlimited_ocr_2" }
  }.freeze

  SERVERS.each do |name, server|
    test "#{name}: transcribes the scanned statement's first page, amounts included" do
      skip "no cassette ai/#{name}/ocr_impact_page; record with RECORD_CASSETTES=1 and #{server[:key]} set" unless ai_cassette_available?(name.to_s, "ocr_impact_page", key: server[:key])
      skip "pdftoppm isn't installed (poppler-utils)" unless system("pdftoppm", "-v", out: File::NULL, err: File::NULL)

      endpoint = Ai::Config::Endpoint.new(name:, protocol: :compatible, preset: server[:preset], base_url: server[:base_url],
                                          api_key: ENV[server[:key]].presence || "recorded", timeout_seconds: 180,
                                          location: server[:base_url]&.start_with?("http:") ? :local : :cloud)
      model = Ai::Config::Model.new(endpoint:, name: server[:model], capabilities: %i[ocr vision], ocr_prompt: server[:ocr_prompt])
      png = Pdf::PageImages.render(file_fixture("statements/impact_scanned.pdf").binread, pages: 1..1).first
      request = Ai::Transport::Base::OcrRequest.new(feature: :extract_pdf, model:, pages: [ Ai::Attachment.png(png, filename: "page-1.png") ])

      match = name == :llama_cpp ? %i[method uri ai_model] : %i[method uri]
      response = with_ai_cassette(name.to_s, "ocr_impact_page", match:) { Ai::Transport.for(endpoint).ocr(request) }

      assert_includes response.text, "763.01"
      assert_includes response.text, "586.71"
    end
  end
end
