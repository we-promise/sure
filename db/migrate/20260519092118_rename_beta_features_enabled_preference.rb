class RenameBetaFeaturesEnabledPreference < ActiveRecord::Migration[7.2]
  # Renames the JSONB preference key `beta_features_enabled` to
  # `preview_features_enabled` for every user that has the old key set.
  # The gate was introduced in PR #1829 and never moved past the Goals
  # rollout, so opt-in counts are small — but copying the value across keeps
  # any early adopters opted in after the rename.
  def up
    execute(<<~SQL)
      UPDATE users
      SET preferences = (preferences - 'beta_features_enabled')
        || jsonb_build_object(
          'preview_features_enabled',
          COALESCE(preferences->'preview_features_enabled', preferences->'beta_features_enabled')
        )
      WHERE preferences ? 'beta_features_enabled'
    SQL
  end

  def down
    execute(<<~SQL)
      UPDATE users
      SET preferences = (preferences - 'preview_features_enabled')
        || jsonb_build_object(
          'beta_features_enabled',
          COALESCE(preferences->'beta_features_enabled', preferences->'preview_features_enabled')
        )
      WHERE preferences ? 'preview_features_enabled'
    SQL
  end
end
