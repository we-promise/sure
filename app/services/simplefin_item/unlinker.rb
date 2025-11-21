# frozen_string_literal: true

# DEPRECATED: This thin wrapper remains only for backward compatibility.
# Business logic has moved into `SimplefinItem::Unlinking` (model concern).
# Prefer calling `item.unlink_all!(dry_run: ...)` directly.
class SimplefinItem::Unlinker
  attr_reader :item, :dry_run

  def initialize(item, dry_run: false)
    @item = item
    @dry_run = dry_run
  end

  def unlink_all!
    item.unlink_all!(dry_run: dry_run)
  end
end
