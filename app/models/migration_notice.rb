# Platform-wide registry for action-required notices shown to family admins
# in the UI — typically after an upgrade where the operator must take a manual
# step that can't be auto-migrated (Plaid OAuth redirect URI changes, env-var
# requirements, schema-backfill rake tasks, etc.).
#
# Notices are registered in config/initializers/migration_notices.rb. Each
# notice declares:
#   - key: stable identifier (used for i18n lookup AND dismissal storage)
#   - scope: tag for filtering at render time (e.g. :providers, :billing)
#   - condition: ->(family) { ... } — controls when the notice applies
#   - copyable_value: ->(view) { ... } — optional; renders the clipboard box
#
# View entry point: ApplicationHelper#render_migration_notices(scope:).
# Family-scoped dismissal: Family#dismiss_migration_notice!(key).
class MigrationNotice
  Notice = Struct.new(:key, :scope, :condition, :copyable_value, keyword_init: true)

  ALL = []
  private_constant :ALL

  class << self
    def register(key:, condition:, scope: :platform, copyable_value: nil)
      key = key.to_s
      ALL.reject! { |n| n.key == key }
      ALL << Notice.new(key: key, scope: scope, condition: condition, copyable_value: copyable_value)
    end

    # Returns hashes (not Notice structs) so views don't need to know the
    # internal storage shape.
    def active_for(family:, view:, scope: nil)
      ALL.filter_map do |notice|
        next if scope && notice.scope != scope
        next if family.dismissed_migration_notice?(notice.key)
        next unless notice.condition.call(family)
        { key: notice.key, copyable_value: notice.copyable_value&.call(view) }
      end
    end

    def all
      ALL.dup
    end

    # Test-only: clear the registry between examples that register their own
    # fixtures. Not used in production code.
    def reset!
      ALL.clear
    end
  end
end
