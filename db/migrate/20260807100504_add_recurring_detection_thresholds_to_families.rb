# frozen_string_literal: true

class AddRecurringDetectionThresholdsToFamilies < ActiveRecord::Migration[7.2]
  def change
    change_table :families, bulk: true do |t|
      t.integer :recurring_detection_lookback_months, default: 3, null: false
      t.integer :recurring_detection_min_occurrences, default: 3, null: false
      t.integer :recurring_detection_recent_window_days, default: 45, null: false
      t.integer :recurring_detection_day_tolerance, default: 2, null: false
      t.integer :recurring_detection_day_cluster_stddev, default: 5, null: false
      t.integer :recurring_detection_amount_tolerance_percent, default: 0, null: false
    end

    add_check_constraint :families,
      "recurring_detection_lookback_months >= 1 AND recurring_detection_lookback_months <= 24",
      name: "recurring_detection_lookback_months_range"
    add_check_constraint :families,
      "recurring_detection_min_occurrences >= 2 AND recurring_detection_min_occurrences <= 12",
      name: "recurring_detection_min_occurrences_range"
    add_check_constraint :families,
      "recurring_detection_recent_window_days >= 7 AND recurring_detection_recent_window_days <= 365",
      name: "recurring_detection_recent_window_days_range"
    add_check_constraint :families,
      "recurring_detection_day_tolerance >= 0 AND recurring_detection_day_tolerance <= 14",
      name: "recurring_detection_day_tolerance_range"
    add_check_constraint :families,
      "recurring_detection_day_cluster_stddev >= 1 AND recurring_detection_day_cluster_stddev <= 15",
      name: "recurring_detection_day_cluster_stddev_range"
    add_check_constraint :families,
      "recurring_detection_amount_tolerance_percent >= 0 AND recurring_detection_amount_tolerance_percent <= 25",
      name: "recurring_detection_amount_tolerance_percent_range"
  end
end
