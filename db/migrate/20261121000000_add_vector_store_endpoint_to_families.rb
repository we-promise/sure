# An OpenAI vector store lives on the server that created it. Recording that server's URL lets
# deletion and index polls reach the store after the configured endpoint changes, instead of
# sending its id to another server.
class AddVectorStoreEndpointToFamilies < ActiveRecord::Migration[8.1]
  def change
    add_column :families, :vector_store_endpoint, :string
  end
end
