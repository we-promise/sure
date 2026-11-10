require "test_helper"
require_relative "../../support/document_store_test_adapter"

class Family::VectorSearchableTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @first_adapter = DocumentStoreTestAdapter.new("first")
    @second_adapter = DocumentStoreTestAdapter.new("second")
    VectorStore::Openai.stubs(:new).with(access_token: "first-key", use_global_settings: false).returns(@first_adapter)
    VectorStore::Openai.stubs(:new).with(access_token: "second-key", use_global_settings: false).returns(@second_adapter)
    configure(@family, "first-key")
  end

  test "first upload creates and binds a family store without changing the legacy store or documents" do
    @family.update!(vector_store_id: "vs_legacy")
    legacy = family_documents(:tax_return)
    original = legacy.attributes

    document = upload

    assert_equal "vs_first_1", document.family_document_store.provider_store_id
    assert_equal @family.id, document.family_document_store.family_id
    assert_equal "vs_legacy", @family.reload.vector_store_id
    assert_equal original, legacy.reload.attributes
    assert_equal [ "vs_first_1" ], @first_adapter.created_stores
  end

  test "same credentials in different families still create separate stores" do
    other = families(:empty)
    configure(other, "first-key")

    first = upload
    second = other.upload_document(file_content: "other", filename: "other.txt")

    assert_not_equal first.family_document_store_id, second.family_document_store_id
    assert_not_equal first.family_document_store.provider_store_id, second.family_document_store.provider_store_id
    assert_not_equal first.family_document_store.credential_fingerprint, second.family_document_store.credential_fingerprint
  end

  test "rotation selects a new store and restoring the original key selects the original store" do
    first = upload
    first_store = first.family_document_store
    configure(@family, "second-key")

    assert_empty @family.search_documents("old content")
    assert_not @family.remove_document(first)
    second = upload
    @family.search_documents("new content")

    assert_not_equal first.family_document_store_id, second.family_document_store_id
    assert_equal [ "vs_second_1" ], @second_adapter.searches
    assert_empty @first_adapter.removals
    assert_equal first_store.attributes, first_store.reload.attributes
    assert first.reload.persisted?

    configure(@family, "first-key")
    @family.search_documents("restored content")
    assert_equal [ "vs_first_1" ], @first_adapter.searches
    assert_equal "vs_first_1", @family.ensure_vector_store!
    assert_equal 1, @first_adapter.created_stores.size
  end

  test "upload finishing after rotation retains the original credential store binding" do
    @first_adapter.on_upload = -> { configure(@family, "second-key") }

    first = upload
    second = upload

    assert_equal "vs_first_1", first.family_document_store.provider_store_id
    assert_equal "vs_second_1", second.family_document_store.provider_store_id
    assert_equal [ { store_id: "vs_first_1", filename: "notes.txt" } ], @first_adapter.uploads
    assert_equal [ { store_id: "vs_second_1", filename: "notes.txt" } ], @second_adapter.uploads
  end

  test "rotation before first store creation cannot retarget the captured context" do
    captured = @family.document_store_context
    configure(@family, "second-key")

    assert_equal "vs_first_1", captured.ensure_store!
    assert_equal "vs_second_1", upload.family_document_store.provider_store_id
    assert_equal "vs_first_1", captured.store_id
    assert_equal 2, @family.document_stores.count
  end

  test "restoring OpenAI after unsupported provider switches recovers only its exact credential store" do
    document = upload
    configuration = Family::AiConfiguration.find_by!(family: @family)
    [ "anthropic", "openrouter" ].each do |provider|
      configuration.update!(provider: provider, model: "anthropic/claude-sonnet-4", api_key: "other-provider-key")
      assert_nil @family.document_store_context.adapter
      assert_nil @family.document_store_context.store_id
      configure(@family, "first-key")
      assert_equal document.family_document_store.provider_store_id, @family.document_store_context.store_id
      configuration.reload
    end
    assert_equal 1, @family.document_stores.count
  end

  test "remote store failure leaves no usable store or uploaded document" do
    @family.update!(vector_store_id: "vs_legacy")
    @first_adapter.expects(:create_store).returns(VectorStore::Response.new(success?: false, data: nil, error: VectorStore::Error.new("Unavailable")))

    assert_no_difference "FamilyDocument.count" do
      assert_nil upload
    end
    assert_nil @family.document_store_context.store_id
    assert_empty @first_adapter.uploads
    assert_equal "vs_legacy", @family.reload.vector_store_id
  end

  test "failure to persist a newly created store cleans up only that context's new remote store" do
    original = upload.family_document_store
    configure(@family, "second-key")
    Family::DocumentStore.any_instance.expects(:update!).with(provider_store_id: "vs_second_1").raises(ActiveRecord::RecordInvalid)
    @second_adapter.expects(:delete_store).with(store_id: "vs_second_1").returns(VectorStore::Response.new(success?: true, data: nil, error: nil))
    @first_adapter.expects(:delete_store).never

    assert_raises(ActiveRecord::RecordInvalid) { upload }

    assert_equal "vs_first_1", original.reload.provider_store_id
    assert_equal 1, @family.document_stores.count
    assert_nil @family.document_store_context.store_id
  end

  test "rotation during search does not mix the original store and new credentials" do
    upload
    @first_adapter.on_search = -> { configure(@family, "second-key") }

    assert_equal 1, @family.search_documents("income").size
    assert_equal [ "vs_first_1" ], @first_adapter.searches
    assert_empty @second_adapter.searches
    assert_empty @family.search_documents("income")
  end

  test "rotation during removal only removes the originally selected document" do
    document = upload
    @first_adapter.on_remove = -> { configure(@family, "second-key") }

    assert @family.remove_document(document)
    assert_equal [ { store_id: "vs_first_1", file_id: document.provider_file_id } ], @first_adapter.removals
    assert_empty @second_adapter.removals
    assert_not FamilyDocument.exists?(document.id)
    assert @family.document_stores.exists?(document.family_document_store_id)
  end

  test "provider switching disables family document operations and preserves both store histories" do
    @family.update!(vector_store_id: "vs_legacy")
    document = upload
    configuration = Family::AiConfiguration.find_by!(family: @family)
    configuration.update!(provider: "anthropic", api_key: "anthropic-key")
    VectorStore::Registry.expects(:build_adapter).never

    assert_nil VectorStore.adapter(family: @family)
    assert_nil upload
    assert_nil @family.ensure_vector_store!
    assert_empty @family.search_documents("anything")
    assert_not @family.remove_document(document)
    assert_equal "vs_legacy", @family.reload.vector_store_id
    assert document.reload.persisted?
    assert_equal "vs_first_1", document.family_document_store.provider_store_id
  end

  test "unreadable credentials fail closed without touching global data" do
    @family.update!(vector_store_id: "vs_legacy")
    Family::AiConfiguration.find_by!(family: @family).update_column(:encrypted_api_key, "corrupted")
    VectorStore::Registry.expects(:build_adapter).never

    assert_nil upload
    assert_empty @family.search_documents("anything")
    assert_not @family.remove_document(family_documents(:tax_return))
    assert_equal "vs_legacy", @family.reload.vector_store_id
  end

  test "cross-family document removal is rejected before resolving a provider" do
    other = families(:empty)
    document = upload
    VectorStore.expects(:context).never

    assert_not other.remove_document(document)
    assert_empty @first_adapter.removals
    assert document.reload.persisted?
  end

  test "legacy documents cannot be removed through the family adapter" do
    @family.update!(vector_store_id: "vs_legacy")
    upload

    assert_not @family.remove_document(family_documents(:tax_return))
    assert_empty @first_adapter.removals
  end

  test "removing an override restores legacy routing without rebinding family-owned documents" do
    @family.update!(vector_store_id: "vs_legacy")
    document = upload
    Family::AiConfiguration.find_by!(family: @family).destroy!
    global = DocumentStoreTestAdapter.new("global")
    VectorStore::Registry.stubs(:adapter).with().returns(global)

    assert_not @family.remove_document(document)
    @family.search_documents("legacy")
    assert_equal [ "vs_legacy" ], global.searches
    assert_empty global.removals
    assert document.reload.persisted?
  end

  test "a cached absent configuration cannot cause global fallback after an override is saved" do
    Family::AiConfiguration.find_by!(family: @family).destroy!
    stale_family = Family.find(@family.id)
    assert_nil stale_family.ai_configuration
    configure(@family, "first-key")
    VectorStore::Registry.expects(:build_adapter).never

    assert_same @first_adapter, stale_family.document_store_context.adapter
  end

  test "a stale configuration association cannot use the previous key after rotation" do
    assert_equal "first-key", @family.ai_configuration.api_key
    configure(Family.find(@family.id), "second-key")

    assert_same @second_adapter, @family.document_store_context.adapter
  end

  test "new documents cannot bind to another family's store" do
    store = upload.family_document_store
    document = families(:empty).family_documents.build(filename: "other.txt", status: "ready", family_document_store: store)

    assert_not document.valid?
    assert_includes document.errors[:family_document_store], "must belong to the same family"
  end

  test "existing store and document ownership cannot be rewritten" do
    document = upload
    store = document.family_document_store
    assert_not store.update(provider_store_id: "vs_rebound")
    assert_not store.update(family: families(:empty))
    assert_not document.update(family_document_store: nil)
    assert_equal store.id, document.reload.family_document_store_id
  end

  test "credential fingerprints are keyed stable and omitted from serialization" do
    store = upload.family_document_store
    digest = store.credential_fingerprint
    assert_match(/\A[0-9a-f]{64}\z/, digest)
    assert_not_includes digest, "first-key"
    assert_not_equal Digest::SHA256.hexdigest("first-key"), digest
    assert_not_includes store.to_json, digest
    assert_not_includes store.to_json(methods: :credential_fingerprint), digest
    assert_not_includes store.inspect, digest
    assert_equal digest, Family::DocumentStore.fingerprint(family_id: @family.id, provider: "openai", api_key: "first-key")
  end

  private
    def configure(family, key)
      configuration = Family::AiConfiguration.find_or_initialize_by(family: family)
      configuration.update!(provider: "openai", api_key: key)
    end

    def upload
      @family.upload_document(file_content: "hello", filename: "notes.txt")
    end
end
