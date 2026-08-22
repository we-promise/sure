class AddSureImportVerificationToImports < ActiveRecord::Migration[7.2]
  def change
    add_column :imports, :expected_record_counts, :jsonb, null: false, default: {}
    add_column :imports, :readback_verification, :jsonb, null: false, default: {}
  end
end
