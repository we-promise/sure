class AddTemplateKeyToInsights < ActiveRecord::Migration[7.2]
  def change
    # Rows carrying a template_key render their title and template body live
    # in the viewer's locale; `body` is only stored when an LLM wrote it, so
    # it becomes nullable. Rows predating this column keep their snapshotted
    # prose until GenerateInsightsJob refreshes them in place.
    add_column :insights, :template_key, :string
    change_column_null :insights, :body, true
  end
end
