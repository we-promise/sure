class MigrateDynamicFieldsToIndividualEntries < ActiveRecord::Migration[7.2]
  def up
    # Find the dynamic_fields setting record
    dynamic_fields_record = Setting.find_by(var: "dynamic_fields")
    return unless dynamic_fields_record

    # Parse the hash and create individual entries
    dynamic_fields_hash = dynamic_fields_record.value || {}
    dynamic_fields_hash.each do |key, value|
      Setting.create!(
        var: "dynamic:#{key}",
        value: value
      )
    end

    # Delete the old dynamic_fields record
    dynamic_fields_record.destroy
  end

  def down
    # Collect all dynamic: entries back into a hash
    dynamic_fields_hash = {}
    Setting.where("var LIKE ?", "dynamic:%").find_each do |record|
      key = record.var.sub(/^dynamic:/, "")
      dynamic_fields_hash[key] = record.value
      record.destroy
    end

    # Recreate the dynamic_fields record with the hash
    Setting.create!(
      var: "dynamic_fields",
      value: dynamic_fields_hash
    ) if dynamic_fields_hash.any?
  end
end
