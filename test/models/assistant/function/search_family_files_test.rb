require "test_helper"

class Assistant::Function::SearchFamilyFilesTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @function = Assistant::Function::SearchFamilyFiles.new(@user)
  end

  def build_statement(family, filename, **attrs)
    statement = family.account_statements.build(
      filename: filename,
      content_type: "application/pdf",
      byte_size: 42,
      checksum: SecureRandom.hex(16),
      content_sha256: SecureRandom.hex(32),
      source: :manual_upload,
      upload_status: :stored,
      review_status: :unmatched,
      currency: "USD",
      **attrs
    )
    statement.original_file.attach(io: StringIO.new("%PDF-1.4 fake"), filename: filename,
                                   content_type: "application/pdf")
    statement.save!
    statement
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

  # These two used to assert an error of "no_documents" / "provider_not_configured".
  # Both were read by assistants as "the user has uploaded nothing", which is a
  # different claim from "no store was ever created" and was false whenever a
  # statement sat in the vault. The tool now degrades to a metadata-only search
  # and names the real reason.
  test "degrades to metadata search when the family has no vector store" do
    @user.family.update!(vector_store_id: nil)

    result = @function.call("query" => "tax return")

    assert_equal true, result[:success]
    assert_equal "metadata_only", result[:search_mode]
    assert_equal "no_vector_store", result[:reason]
  end

  test "degrades to metadata search when no adapter is available and says why" do
    @user.family.update!(vector_store_id: "vs_test123")
    VectorStore::Registry.stubs(:adapter).returns(nil)

    result = @function.call("query" => "tax return")

    assert_equal true, result[:success]
    assert_equal "provider_not_configured", result[:reason]
    assert_match(/VECTOR_STORE_PROVIDER/, result[:message])
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

  test "never claims nothing was uploaded when statements are on file" do
    family = @user.family
    family.update!(vector_store_id: nil)

    statement = build_statement(family, "releve-septembre.pdf",
                                period_start_on: Date.new(2026, 9, 1),
                                period_end_on: Date.new(2026, 9, 30))

    result = Assistant::Function::SearchFamilyFiles.new(@user).call("query" => "releve")

    assert_equal true, result[:success]
    assert_equal "metadata_only", result[:search_mode]
    assert_equal "no_vector_store", result[:reason]
    assert_includes result[:results].map { |r| r[:account_statement_id] }, statement.id
    assert_no_match(/No documents have been uploaded/, result[:message])
    assert_match(/get_document_text/, result[:message])
  end

  # Every other vault tool gates on statement_manager? first. Without the same
  # gate here, full-text search simply being unconfigured became a way around
  # the role check, and unlinked statements are exactly what viewable_by?
  # reserves to a manager.
  test "a guest gets no vault inventory from the fallback" do
    family = @user.family
    family.update!(vector_store_id: nil)
    build_statement(family, "releve-prive.pdf")

    guest = users(:family_member)
    guest.update!(role: "guest")

    result = Assistant::Function::SearchFamilyFiles.new(guest).call("query" => "releve")

    assert_equal 0, result[:result_count]
    assert_empty result[:results]
    assert_match(/admin or member role/, result[:message])
    assert_no_match(/releve-prive/, result.to_s)
  end

  # The document store is family-wide by construction, and this branch started
  # feeding it every vault upload. A statement on an account the caller cannot
  # see must not come back through the vector path either.
  test "drops content from a document on an account the caller cannot access" do
    family = @user.family
    family.update!(vector_store_id: "vs_test123")

    private_account = family.accounts.create!(
      accountable: Depository.new, owner: users(:family_member),
      name: "Jakob Checking", balance: 500, currency: "USD"
    )

    family.family_documents.create!(
      filename: "fiche-de-paie.pdf", content_type: "application/pdf", file_size: 42,
      provider_file_id: "file-private", status: "ready",
      account: private_account
    )

    mock_adapter = mock("vector_store_adapter")
    mock_adapter.stubs(:search).returns(
      VectorStore::Response.new(
        success?: true,
        data: [
          { content: "Salaire net 3 200,00", filename: "fiche-de-paie.pdf", score: 0.9, file_id: "file-private" },
          { content: "Loyer 900,00", filename: "quittance.pdf", score: 0.8, file_id: "file-shared" }
        ],
        error: nil
      )
    )
    VectorStore::Registry.stubs(:adapter).returns(mock_adapter)

    result = Assistant::Function::SearchFamilyFiles.new(@user).call("query" => "salaire")

    assert_equal 1, result[:result_count]
    assert_equal "quittance.pdf", result[:results].first[:filename]
    assert_no_match(/Salaire net/, result.to_s)
  end

  test "says plainly when nothing is on file at all" do
    family = @user.family
    family.update!(vector_store_id: nil)
    family.account_statements.destroy_all

    result = Assistant::Function::SearchFamilyFiles.new(@user).call("query" => "anything")

    assert_equal 0, result[:result_count]
    assert_match(/genuinely nothing on file/, result[:message])
  end

  test "an over-specific query still lists what exists rather than reading as empty" do
    family = @user.family
    family.update!(vector_store_id: nil)

    build_statement(family, "releve.pdf")

    result = Assistant::Function::SearchFamilyFiles.new(@user).call("query" => "zzzznotamatchzzzz")

    assert_equal 1, result[:result_count]
  end
end
