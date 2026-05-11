class Savings::GoalAvatarComponent < ApplicationComponent
  SIZES = {
    "sm" => { box: "w-6 h-6", text: "text-[10px]", radius: "rounded-md" },
    "md" => { box: "w-9 h-9", text: "text-sm", radius: "rounded-lg" },
    "lg" => { box: "w-11 h-11", text: "text-base", radius: "rounded-xl" },
    "xl" => { box: "w-16 h-16", text: "text-2xl", radius: "rounded-2xl" }
  }.freeze

  def initialize(goal: nil, name: nil, color: nil, size: "md")
    @goal = goal
    @name = name || goal&.name
    @color = color || goal&.color || SavingsGoal::COLORS.first
    @size = SIZES.key?(size) ? size : "md"
  end

  attr_reader :color

  def initial
    return "?" if @name.blank?
    @name.strip.first&.upcase || "?"
  end

  def box_classes
    SIZES[@size][:box]
  end

  def text_classes
    SIZES[@size][:text]
  end

  def radius_classes
    SIZES[@size][:radius]
  end
end
