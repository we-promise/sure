# No provider traffic: records which immutable store receives each operation.
class DocumentStoreTestAdapter
  attr_reader :created_stores, :uploads, :searches, :removals
  attr_accessor :on_create, :on_upload, :on_search, :on_remove

  def initialize(prefix = "test")
    @prefix = prefix
    @mutex = Mutex.new
    @created_stores = []
    @uploads = []
    @searches = []
    @removals = []
  end

  def create_store(name:)
    id = @mutex.synchronize do
      id = "vs_#{@prefix}_#{created_stores.size + 1}"
      created_stores << id
      id
    end
    on_create&.call
    success(id: id)
  end

  def upload_file(store_id:, file_content:, filename:)
    file_id = @mutex.synchronize do
      uploads << { store_id: store_id, filename: filename }
      "file_#{@prefix}_#{uploads.size}"
    end
    on_upload&.call
    success(file_id: file_id)
  end

  def search(store_id:, query:, max_results:)
    searches << store_id
    on_search&.call
    success([ { content: query, filename: "notes.txt", score: 1.0 } ])
  end

  def remove_file(store_id:, file_id:)
    removals << { store_id: store_id, file_id: file_id }
    on_remove&.call
    success(nil)
  end

  private
    def success(data)
      VectorStore::Response.new(success?: true, data: data, error: nil)
    end
end
