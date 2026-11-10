require "test_helper"

class Assistant::Function::SearchFamilyFilesTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @function = Assistant::Function::SearchFamilyFiles.new(@user)
  end

  test "has correct name" do
    assert_equal "search_family_files", @function.name
  end

  test "has a description" do
    assert_not_empty @function.description
  end

  test "is not in strict mode" do
    assert_not @function.strict_mode?
  end

  test "params_schema requires query" do
    schema = @function.params_schema
    assert_includes schema[:required], "query"
    assert schema[:properties].key?(:query)
  end

  test "generates valid tool definition" do
    definition = @function.to_definition
    assert_equal "search_family_files", definition[:name]
    assert_not_nil definition[:description]
    assert_not_nil definition[:params_schema]
    assert_equal false, definition[:strict]
  end

  test "returns no_documents error when family has no vector store" do
    @user.family.update!(vector_store_id: nil)

    result = @function.call("query" => "tax return")

    assert_equal false, result[:success]
    assert_equal "no_documents", result[:error]
  end

  test "returns provider_not_configured when no adapter is available" do
    @user.family.update!(vector_store_id: "vs_test123")
    VectorStore::Registry.stubs(:adapter).returns(nil)

    result = @function.call("query" => "tax return")

    assert_equal false, result[:success]
    assert_equal "provider_not_configured", result[:error]
  end

  test "returns search results on success" do
    @user.family.update!(vector_store_id: "vs_test123")

    mock_adapter = mock("vector_store_adapter")
    mock_adapter.stubs(:search).returns(
      VectorStore::Response.new(
        success?: true,
        data: [
          { content: "Total income: $85,000", filename: "2024_tax_return.pdf", score: 0.95, file_id: "file-abc" },
          { content: "W-2 wages: $80,000", filename: "2024_tax_return.pdf", score: 0.87, file_id: "file-abc" }
        ],
        error: nil
      )
    )

    VectorStore::Registry.stubs(:adapter).returns(mock_adapter)

    result = @function.call("query" => "What was my total income?")

    assert_equal true, result[:success]
    assert_equal 2, result[:result_count]
    assert_equal "Total income: $85,000", result[:results].first[:content]
    assert_equal "2024_tax_return.pdf", result[:results].first[:filename]
  end

  test "returns empty results message when no matches found" do
    @user.family.update!(vector_store_id: "vs_test123")

    mock_adapter = mock("vector_store_adapter")
    mock_adapter.stubs(:search).returns(
      VectorStore::Response.new(success?: true, data: [], error: nil)
    )

    VectorStore::Registry.stubs(:adapter).returns(mock_adapter)

    result = @function.call("query" => "nonexistent document")

    assert_equal true, result[:success]
    assert_empty result[:results]
  end

  test "handles search failure gracefully" do
    @user.family.update!(vector_store_id: "vs_test123")

    mock_adapter = mock("vector_store_adapter")
    mock_adapter.stubs(:search).returns(
      VectorStore::Response.new(
        success?: false,
        data: nil,
        error: VectorStore::Error.new("API rate limit exceeded")
      )
    )

    VectorStore::Registry.stubs(:adapter).returns(mock_adapter)

    result = @function.call("query" => "tax return")

    assert_equal false, result[:success]
    assert_equal "search_failed", result[:error]
  end

  test "caps max_results at 20" do
    @user.family.update!(vector_store_id: "vs_test123")

    mock_adapter = mock("vector_store_adapter")
    mock_adapter.expects(:search).with(
      store_id: "vs_test123",
      query: "test",
      max_results: 20
    ).returns(VectorStore::Response.new(success?: true, data: [], error: nil))

    VectorStore::Registry.stubs(:adapter).returns(mock_adapter)

    @function.call("query" => "test", "max_results" => 50)
  end

  test "returns the search failure when tracing finalization also fails" do
    @user.family.update!(vector_store_id: "vs_test123")
    adapter = mock
    adapter.expects(:search).raises(StandardError, "Search unavailable")
    VectorStore::Registry.stubs(:adapter).returns(adapter)
    trace = mock
    trace.expects(:end).with(output: { error: "Search unavailable" }, level: "ERROR").raises(StandardError, "Tracing unavailable")
    @function.stubs(:create_langfuse_trace).returns(trace)
    Rails.logger.expects(:warn).with("Langfuse trace finalization failed: StandardError: Tracing unavailable")

    result = @function.call("query" => "tax return")

    assert_equal false, result[:success]
    assert_equal "search_failed", result[:error]
    assert_equal "An error occurred while searching documents: Search unavailable", result[:message]
  end

  test "explicit family non-OpenAI configuration cannot search a legacy store" do
    family = @user.family
    family.update!(vector_store_id: "vs_legacy")
    Family::AiConfiguration.create!(family: family, provider: "anthropic", api_key: "family-key")
    VectorStore::Registry.expects(:build_adapter).never

    result = @function.call("query" => "tax return")

    assert_equal false, result[:success]
    assert_equal "provider_not_configured", result[:error]
  end

  test "family search uses its credential store instead of the legacy store" do
    family = @user.family
    family.update!(vector_store_id: "vs_legacy")
    Family::AiConfiguration.create!(family: family, provider: "openai", api_key: "family-key")
    family.document_stores.create!(
      provider: "openai", provider_store_id: "vs_family",
      credential_fingerprint: Family::DocumentStore.fingerprint(family_id: family.id, provider: "openai", api_key: "family-key")
    )
    adapter = mock("family adapter")
    VectorStore::Openai.expects(:new).with(access_token: "family-key", use_global_settings: false).returns(adapter)
    adapter.expects(:search).with(store_id: "vs_family", query: "income", max_results: 10)
      .returns(VectorStore::Response.new(success?: true, data: [], error: nil))

    assert @function.call("query" => "income")[:success]
  end

  test "family search does not reuse legacy documents before its first upload" do
    family = @user.family
    family.update!(vector_store_id: "vs_legacy")
    Family::AiConfiguration.create!(family: family, provider: "openai", api_key: "family-key")
    adapter = mock("family adapter")
    VectorStore::Openai.expects(:new).with(access_token: "family-key", use_global_settings: false).returns(adapter)
    adapter.expects(:search).never

    result = @function.call("query" => "income")

    assert_equal "no_documents", result[:error]
  end
end
