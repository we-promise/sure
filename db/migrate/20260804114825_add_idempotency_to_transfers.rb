class AddIdempotencyToTransfers < ActiveRecord::Migration[8.1]
  def change
    add_column :transfers, :external_id, :string
    add_column :transfers, :idempotency_fingerprint, :string
    add_index :transfers, :external_id, unique: true, where: "external_id IS NOT NULL"
  end
end
