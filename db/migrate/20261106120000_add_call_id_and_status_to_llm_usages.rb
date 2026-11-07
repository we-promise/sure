# One llm_usages row per request, grouped per call. Rows written before this, and rows the
# per-provider usage recorders write, have no call_id: each counts as a call of one request.
class AddCallIdAndStatusToLlmUsages < ActiveRecord::Migration[8.1]
  STATUSES = %w[succeeded failed cancelled].freeze

  def up
    add_column :llm_usages, :call_id, :uuid
    add_column :llm_usages, :status, :string, null: false, default: "succeeded"
    add_index :llm_usages, :call_id
    add_check_constraint :llm_usages, "status IN (#{STATUSES.map { "'#{_1}'" }.join(", ")})", name: "chk_llm_usages_status"

    # The per-provider recorders mark a failed request by putting its error in metadata. An error
    # that's blank by LlmUsage's `present?` check (missing, null, false, only whitespace, an
    # empty object or array) was never shown as a failure and isn't one now. Rails counts Unicode
    # spaces as blank whatever the locale, so they're listed rather than left to the database's.
    execute <<~'SQL'
      UPDATE llm_usages SET status = 'failed'
      WHERE CASE jsonb_typeof(metadata->'error')
              WHEN 'string' THEN metadata->>'error' ~ '[^[:space:]\u0085\u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000]'
              WHEN 'object' THEN metadata->'error' <> '{}'::jsonb
              WHEN 'array' THEN metadata->'error' <> '[]'::jsonb
              WHEN 'boolean' THEN (metadata->'error')::boolean
              WHEN 'number' THEN true
              ELSE false
            END
    SQL
  end

  def down
    remove_check_constraint :llm_usages, name: "chk_llm_usages_status"
    remove_index :llm_usages, :call_id
    remove_column :llm_usages, :status
    remove_column :llm_usages, :call_id
  end
end
