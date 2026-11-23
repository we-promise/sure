# The prompt overrides the key collapse (20261106130000) set aside move from debug_log_entries to
# families.ai_prompt_overrides["dropped"] ({ key => text }), so the text's only copy no longer
# depends on the debug log being kept. A family with two entries for one key keeps the newest.
class MoveDroppedAiPromptOverridesToFamilies < ActiveRecord::Migration[8.1]
  CATEGORY = "ai_prompt_override_dropped".freeze
  DROPPED_KEY = "dropped".freeze

  def up
    rows = select_all(sanitize([ "SELECT family_id, metadata FROM debug_log_entries WHERE category = ? AND family_id IS NOT NULL ORDER BY created_at", CATEGORY ]))
    rows.group_by { _1["family_id"] }.each do |family_id, entries|
      dropped = entries.to_h { |entry| metadata = json(entry["metadata"]); [ metadata["key"], metadata["text"] ] }.compact_blank
      next if dropped.empty?

      execute sanitize([ <<~SQL, dropped.to_json, family_id ])
        UPDATE families
        SET ai_prompt_overrides = jsonb_set(COALESCE(ai_prompt_overrides, '{}'::jsonb), '{#{DROPPED_KEY}}',
                                            COALESCE(ai_prompt_overrides -> '#{DROPPED_KEY}', '{}'::jsonb) || ?::jsonb)
        WHERE id = ?
      SQL
    end
    execute sanitize([ "DELETE FROM debug_log_entries WHERE category = ?", CATEGORY ])
  end

  def down
    rows = select_all("SELECT id, ai_prompt_overrides -> '#{DROPPED_KEY}' AS dropped FROM families WHERE ai_prompt_overrides ? '#{DROPPED_KEY}'")
    rows.each do |row|
      json(row["dropped"]).each do |key, text|
        execute sanitize([
          "INSERT INTO debug_log_entries (id, category, level, message, source, family_id, metadata, created_at, updated_at) " \
          "VALUES (gen_random_uuid(), ?, 'warn', ?, ?, ?, ?::jsonb, now(), now())",
          CATEGORY, "A prompt override was dropped when the per-provider overrides merged", "CollapseAiPromptOverrideKeys",
          row["id"], { key:, text: }.to_json
        ])
      end
      execute sanitize([ "UPDATE families SET ai_prompt_overrides = ai_prompt_overrides - ? WHERE id = ?", DROPPED_KEY, row["id"] ])
    end
  end

  private
    def sanitize(statement) = ActiveRecord::Base.sanitize_sql(statement)

    def json(value) = value.is_a?(String) ? JSON.parse(value) : value.to_h
end
