class CreatePhysicalCashes < ActiveRecord::Migration[7.2]
  def change
    create_table :physical_cashes, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.string :subtype
      t.jsonb :locked_attributes, default: {}
      t.timestamps
    end
  end
end
