class ValidatePreciousMetalLotImportMappings < ActiveRecord::Migration[8.1]
  def change
    validate_check_constraint :import_source_mappings, name: "chk_import_source_mappings_source_type"
    validate_check_constraint :import_source_mappings, name: "chk_import_source_mappings_target_type"
  end
end
