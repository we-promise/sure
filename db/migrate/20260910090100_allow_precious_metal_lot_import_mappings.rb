class AllowPreciousMetalLotImportMappings < ActiveRecord::Migration[8.1]
  TYPES = %w[Account Category Tag Merchant RecurringTransaction RecurringOccurrence Transaction Budget Security Rule].freeze

  def up
    replace_constraints(TYPES + [ "PreciousMetalLot" ], validate: false)
  end

  def down
    execute <<~SQL.squish
      DELETE FROM import_source_mappings
      WHERE source_type = 'PreciousMetalLot'
         OR target_type = 'PreciousMetalLot'
    SQL
    replace_constraints(TYPES, validate: true)
  end

  private
    def replace_constraints(types, validate:)
      %w[source_type target_type].each do |column|
        name = "chk_import_source_mappings_#{column}"
        remove_check_constraint :import_source_mappings, name: name
        values = types.map { |type| connection.quote(type) }.join(", ")
        add_check_constraint :import_source_mappings, "#{column} IN (#{values})", name: name, validate: validate
      end
    end
end
