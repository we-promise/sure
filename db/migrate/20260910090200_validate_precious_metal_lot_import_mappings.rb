class ValidatePreciousMetalLotImportMappings < ActiveRecord::Migration[8.1]
  def up
    validate_check_constraint :import_source_mappings, name: "chk_import_source_mappings_source_type"
    validate_check_constraint :import_source_mappings, name: "chk_import_source_mappings_target_type"
  end

  # PostgreSQL cannot mark a validated constraint as unvalidated. The prior
  # migration removes and recreates these constraints when it is rolled back.
  def down
  end
end
