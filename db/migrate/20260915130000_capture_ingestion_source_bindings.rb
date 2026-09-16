class CaptureIngestionSourceBindings < ActiveRecord::Migration[8.1]
  def change
    add_column :ingestion_batches, :source_binding, :jsonb, null: false, default: {}
    add_check_constraint :ingestion_batches, "jsonb_typeof(source_binding) = 'object'", name: "chk_ib_source_binding"
  end
end
