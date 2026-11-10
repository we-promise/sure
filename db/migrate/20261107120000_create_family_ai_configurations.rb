class CreateFamilyAiConfigurations < ActiveRecord::Migration[8.1]
  def change
    create_table :family_ai_configurations, id: :uuid do |t|
      t.references :family, type: :uuid, null: false, foreign_key: true, index: { unique: true }
      t.string :provider, null: false
      t.string :model, null: false
      t.text :encrypted_api_key, null: false
      t.timestamps
    end

    add_check_constraint :family_ai_configurations,
                         "provider IN ('openai', 'anthropic', 'openrouter')",
                         name: "chk_family_ai_configurations_provider"
  end
end
