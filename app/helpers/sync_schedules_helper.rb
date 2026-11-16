module SyncSchedulesHelper
  # The "Sync frequency" entry of a connection card's menu. Every provider card
  # has its own partial; this is the one line they all share. Left out for a
  # viewer the editor would turn away, whatever the card's own menu shows.
  def sync_schedule_menu_item(menu, syncable)
    return unless SyncSchedule.editable_by?(syncable, Current.user)

    menu.with_item(
      variant: "link",
      text: t("sync_schedules.menu_item"),
      icon: "clock",
      href: edit_sync_schedule_path(syncable_type: syncable.class.name, syncable_id: syncable.id),
      frame: :modal
    )
  end

  def sync_schedule_interval_options
    SyncSchedule::INTERVALS.map { |minutes| [ sync_schedule_interval_label(minutes), minutes ] }
  end

  def sync_schedule_interval_label(minutes)
    if minutes < 60
      t("sync_schedules.intervals.minutes", count: minutes)
    else
      t("sync_schedules.intervals.hours", count: minutes / 60)
    end
  end

  # Not every provider item has a name (FinanceKit's doesn't).
  def sync_schedule_syncable_name(syncable)
    syncable.try(:name).presence || syncable.model_name.human
  end
end
