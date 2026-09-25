class AddAiProviderToImports < ActiveRecord::Migration[7.2]
  def change
    add_column :imports, :ai_provider, :string, null: false, default: "api"
    add_check_constraint :imports, "ai_provider IN ('api', 'codex')", name: "chk_imports_ai_provider"
  end
end
