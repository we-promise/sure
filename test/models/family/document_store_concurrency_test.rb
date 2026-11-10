require "test_helper"
require "concurrent"
require_relative "../../support/document_store_test_adapter"

class Family::DocumentStoreConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @family = Family.create!(name: "Document store concurrency", currency: "USD")
    Family::AiConfiguration.create!(family: @family, provider: "openai", api_key: "concurrent-key")
    @adapter = DocumentStoreTestAdapter.new("concurrent")
    VectorStore::Openai.stubs(:new).with(access_token: "concurrent-key", use_global_settings: false).returns(@adapter)
  end

  teardown do
    @family&.destroy!
  end

  test "simultaneous first uploads use one remote store and persist matching ownership" do
    run_simultaneous_uploads

    assert_equal [ "vs_concurrent_1" ], @adapter.created_stores
    assert_equal 1, @family.document_stores.count
    assert_equal 2, @family.family_documents.count
    store = @family.document_stores.sole
    assert_equal [ store.id ], @family.family_documents.distinct.pluck(:family_document_store_id)
    assert_equal [ store.provider_store_id ], @adapter.uploads.pluck(:store_id).uniq
    assert_nil @family.reload.vector_store_id
  end

  test "simultaneous first installation-managed uploads still use one legacy store" do
    Family::AiConfiguration.find_by!(family: @family).destroy!
    VectorStore::Registry.stubs(:adapter).with().returns(@adapter)

    run_simultaneous_uploads

    assert_equal [ "vs_concurrent_1" ], @adapter.created_stores
    assert_equal "vs_concurrent_1", @family.reload.vector_store_id
    assert_empty @family.document_stores
    assert_equal 2, @family.family_documents.count
    assert_equal [ nil ], @family.family_documents.distinct.pluck(:family_document_store_id)
  end

  private
    def run_simultaneous_uploads
      ready = Concurrent::CountDownLatch.new(2)
      start = Concurrent::CountDownLatch.new(1)
      workers = 2.times.map do |index|
        Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do |connection|
            connection.execute("SET lock_timeout = '10s'")
            family = Family.find(@family.id)
            ready.count_down
            raise "Concurrent uploads did not start" unless start.wait(5)
            family.upload_document(file_content: "content", filename: "#{index}.txt")
          ensure
            connection.execute("RESET lock_timeout")
          end
        end
      end
      assert ready.wait(5), "Upload workers were not ready"
      start.count_down
      workers.each do |worker|
        assert worker.join(15), "Upload worker did not finish"
        assert worker.value
      end
    ensure
      start&.count_down
      workers&.each do |worker|
        next if worker.join(15)
        worker.kill
        worker.join
      end
    end
end
