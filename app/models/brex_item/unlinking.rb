# frozen_string_literal: true

module BrexItem::Unlinking
  extend ActiveSupport::Concern

  # Permission and every link are rechecked before one atomic detach. Retained
  # migration/policy evidence requires its separate lifecycle disposition.
  def unlink_all!(dry_run: false, actor: Current.user)
    BrexItem::Lifecycle.new(item: self, actor: actor).disconnect(dry_run: dry_run, schedule: false)
  end
end
