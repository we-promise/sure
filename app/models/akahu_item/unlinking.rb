module AkahuItem::Unlinking
  extend ActiveSupport::Concern

  def unlink_all!(dry_run: false, actor: Current.user)
    AkahuItem::Lifecycle.new(item: self, actor: actor).disconnect(dry_run: dry_run, schedule: false)
  end
end
