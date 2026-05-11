class Savings::StatusPillComponent < ApplicationComponent
  VARIANTS = {
    on_track: { classes: "bg-green-600/10 text-green-700", icon: "check" },
    behind:   { classes: "bg-yellow-500/10 text-yellow-700", icon: "alert-triangle" },
    reached:  { classes: "bg-green-600/10 text-green-700", icon: "circle-check-big" },
    no_target_date: { classes: "bg-container-inset text-secondary", icon: "calendar-off" }
  }.freeze

  def initialize(goal:)
    @goal = goal
  end

  def status
    @goal.status
  end

  def variant
    VARIANTS.fetch(status, VARIANTS[:no_target_date])
  end

  def label
    I18n.t("savings_goals.status.#{status}")
  end

  def icon_name
    variant[:icon]
  end

  def classes
    variant[:classes]
  end
end
