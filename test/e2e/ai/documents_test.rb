require "test_helper"

class AiE2eDocumentsTest < ActiveSupport::TestCase
  include AiE2eHelper
  include ActiveJob::TestHelper

  LEASE = <<~TEXT.freeze
    Residential lease for 12 Elm Street. Monthly rent is $1,850, due on the first day of each
    month. A late fee of $75 applies after the fifth. The security deposit is $3,700.
  TEXT
  RECIPE = <<~TEXT.freeze
    Banana bread: mash three ripe bananas, stir in melted butter, sugar, an egg and flour, then
    bake at 350 degrees for an hour.
  TEXT

  setup do
    @user = users(:family_admin)
    @user.update!(ai_enabled: true)
    @family = @user.family
  end

  test "Cohere embeds uploaded documents into pgvector, and the chat's search tool finds the right one" do
    result = with_live_ai(**cohere_embeddings) do
      @family.upload_document_later(uploaded_file(filename: "lease.txt", content_type: "text/plain", content: LEASE))
      @family.upload_document_later(uploaded_file(filename: "recipe.txt", content_type: "text/plain", content: RECIPE))
      perform_enqueued_jobs

      assert_equal "ready", @family.family_documents.find_by(filename: "lease.txt").status
      assert_equal "ready", @family.family_documents.find_by(filename: "recipe.txt").status

      Assistant::Function::SearchFamilyFiles.new(@user).call("query" => "When is my rent due, and what is the late fee?")
    end

    assert result[:success], result.inspect
    assert_equal "lease.txt", result[:results].first[:filename], result.inspect
    assert_ai_usage(@family, :embed)
    assert_ai_usage(@family, :search_documents)
    assert_no_ai_errors
  end
end
