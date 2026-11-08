# The Jev choice moves from the family to the instance: one setting, which the deprecated AI ENV
# path reads. An instance with one family keeps that family's choice; on any other, every family
# goes back to the LLM, and an instance admin who picks Jev picks it for every family.
class MoveCategorizationProviderToSetting < ActiveRecord::Migration[8.1]
  CONSTRAINT = "chk_families_categorization_provider".freeze

  def up
    choices = select_values("SELECT categorization_provider FROM families")
    if choices == [ "jev" ] && setting.nil?
      execute "INSERT INTO settings (var, value, created_at, updated_at) VALUES ('categorization_provider', '--- jev\n', now(), now())"
      clear_settings_cache
    end

    remove_check_constraint :families, name: CONSTRAINT
    remove_column :families, :categorization_provider
  end

  def down
    add_column :families, :categorization_provider, :string, default: "llm", null: false
    add_check_constraint :families, "categorization_provider::text = ANY (ARRAY['llm'::character varying::text, 'jev'::character varying::text])",
                         name: CONSTRAINT

    execute "UPDATE families SET categorization_provider = 'jev'" if setting == "jev" && select_value("SELECT count(*) FROM families").to_i == 1
  end

  private
    def setting
      select_value("SELECT value FROM settings WHERE var = 'categorization_provider'")&.delete_prefix("--- ")&.strip.presence
    end

    # rails-settings-cached keeps every setting in one cache entry, which a raw insert doesn't
    # touch.
    def clear_settings_cache
      Setting.clear_cache
    rescue StandardError
      nil
    end
end
