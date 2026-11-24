require "test_helper"

class Assistant::Function::SearchFamilyFilesTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @function = Assistant::Function::SearchFamilyFiles.new(@user)
    use_ai_routes
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

  test "answers with the router's reason when document search is unavailable" do
    @user.family.update!(vector_store_id: "vs_test123")
    use_no_ai

    result = @function.call("query" => "tax return")

    assert_equal false, result[:success]
    assert_equal "ai_unavailable", result[:error]
    assert_equal "not_configured", result[:reason]
  end

  test "sends the search text nowhere when the user has AI off" do
    @user.family.update!(vector_store_id: "vs_test123")
    @user.update!(ai_enabled: false)
    adapter = mock("vector_store_adapter")
    adapter.expects(:search).never
    VectorStore::Registry.stubs(:adapter).returns(adapter)

    result = @function.call("query" => "tax return")

    assert_equal "user_disabled", result[:reason]
  end

  test "returns search results on success" do
    @user.family.update!(vector_store_id: "vs_test123")

    mock_adapter = mock("vector_store_adapter")
    mock_adapter.stubs(:search).returns(
      VectorStore::Response.new(
        success?: true,
        data: [
          { content: "Total income: $85,000", filename: "2024_tax_return.pdf", score: 0.95, file_id: "file-abc123" },
          { content: "W-2 wages: $80,000", filename: "2024_tax_return.pdf", score: 0.87, file_id: "file-abc123" }
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

  test "returns at most 20 results" do
    chunks = Array.new(30) { |i| chunk("file-abc123", "Excerpt #{i}") }
    stub_search(chunks)

    result = @function.call("query" => "test", "max_results" => 50)

    assert_equal 20, result[:result_count]
  end

  # Statement PDFs are searchable by whoever may see the statement
  # (AccountStatement#viewable_by?); files uploaded straight to the store are
  # the family's.
  test "a member finds no excerpts of a statement of an account not shared with them" do
    hidden = statement_document(account: accounts(:connected))
    shared = statement_document(account: accounts(:depository))
    stub_search([ chunk(hidden, "Admin private"), chunk(shared, "Shared"), chunk("file-abc123", "Family upload") ])

    result = Assistant::Function::SearchFamilyFiles.new(users(:family_member)).call("query" => "statement")

    assert_equal [ "Shared", "Family upload" ], result[:results].map { |r| r[:content] }
  end

  test "the owner of the account finds the excerpts of its statement" do
    hidden = statement_document(account: accounts(:connected))
    stub_search([ chunk(hidden, "Admin private") ])

    result = @function.call("query" => "statement")

    assert_equal [ "Admin private" ], result[:results].map { |r| r[:content] }
  end

  test "a statement linked to an account later follows that account" do
    statement_file = statement_document(account: nil)
    stub_search([ chunk(statement_file, "Inbox statement") ])
    member_search = Assistant::Function::SearchFamilyFiles.new(users(:family_member))

    assert_equal 1, member_search.call("query" => "statement")[:result_count]

    FamilyDocument.find_by!(provider_file_id: statement_file).account_statement.link_to_account!(accounts(:connected))

    assert_empty member_search.call("query" => "statement")[:results]
  end

  test "a guest finds no excerpts of an unlinked statement" do
    statement_file = statement_document(account: nil)
    stub_search([ chunk(statement_file, "Inbox statement"), chunk("file-abc123", "Family upload") ])

    result = Assistant::Function::SearchFamilyFiles.new(family_guest).call("query" => "statement")

    assert_equal [ "Family upload" ], result[:results].map { |r| r[:content] }
  end

  # PDFs processed before documents recorded their statement could come from
  # any account, so nobody finds them until they are linked.
  test "nobody finds a processed PDF whose statement is unknown" do
    @user.family.family_documents.create!(filename: "old.pdf", provider_file_id: "file-legacy", status: "ready",
                                          metadata: { "type" => "bank_statement" })
    stub_search([ chunk("file-legacy", "Legacy statement") ])

    assert_empty @function.call("query" => "statement")[:results]
  end

  test "excerpts of a file the family has no record of are left out" do
    stub_search([ chunk("file-unknown", "Orphan") ])

    assert_empty @function.call("query" => "statement")[:results]
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

  private
    def stub_search(chunks)
      @user.family.update!(vector_store_id: "vs_test123")
      adapter = mock("vector_store_adapter")
      adapter.stubs(:search).returns(VectorStore::Response.new(success?: true, data: chunks, error: nil))
      VectorStore::Registry.stubs(:adapter).returns(adapter)
    end

    def chunk(file_id, content)
      { content: content, filename: "statement.pdf", score: 0.9, file_id: file_id }
    end

    # The provider file id of a document uploaded for a new statement PDF.
    def statement_document(account:)
      family = @user.family
      statement = AccountStatement.create_from_upload!(
        family: family,
        account: account,
        file: uploaded_file(filename: "statement.pdf", content_type: "application/pdf", content: "%PDF-1.4 #{SecureRandom.hex}")
      )
      family.family_documents.create!(filename: statement.filename, provider_file_id: "file-#{SecureRandom.hex(4)}", status: "ready",
                                      account_statement: statement, metadata: { "type" => "bank_statement" }).provider_file_id
    end
end
