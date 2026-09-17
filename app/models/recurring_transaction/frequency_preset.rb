class RecurringTransaction
  # Translates between the frequency picker's presets and recurrence_rules
  # rows. A preset is a named rule shape (biweekly = one weekly rule with
  # interval 2); anything the picker cannot express reads back as CUSTOM and
  # is left untouched.
  class FrequencyPreset
    PRESETS = %w[monthly weekly biweekly semimonthly quarterly semiannual annual].freeze
    CUSTOM = "custom"

    Detection = Data.define(:key, :day_of_month, :second_day_of_month, :weekday, :month_of_year)

    class << self
      # Reads the series' rules back into picker values. Zero rules is the
      # legacy implicit monthly.
      def detect(recurring)
        rules = live_rules(recurring)

        case
        when rules.empty?
          detection(key: "monthly", day_of_month: recurring.expected_day_of_month)
        when rules.size == 1
          detect_single(rules.first)
        when rules.size == 2 && rules.all? { |rule| monthly_day_rule?(rule) }
          days = canonical_semimonthly_days(rules.map(&:day_of_month))
          if days.uniq.size == 1
            detection(key: "monthly", day_of_month: days.first)
          else
            detection(key: "semimonthly", day_of_month: days.first, second_day_of_month: days.last)
          end
        else
          detection(key: CUSTOM)
        end
      end

      # Replaces the series' rules with the preset's shape. Assigns only, so the
      # caller's save persists atomically and invalid input surfaces as normal
      # validation errors. An unchanged cadence is a no-op.
      #
      # Returns true only when it actually rewrote the cadence, so a caller can
      # tell a deliberate schedule change from an unrelated edit.
      def apply(recurring, preset:, day_of_month: nil, second_day_of_month: nil, weekday: nil, month_of_year: nil)
        return false if preset.blank? || preset == CUSTOM
        return false unless PRESETS.include?(preset)

        reference = recurring.anchor_date || recurring.last_occurrence_date || Date.current
        target = target_detection(recurring, reference, preset,
                                  day_of_month: presence_int(day_of_month),
                                  second_day_of_month: presence_int(second_day_of_month),
                                  weekday: presence_int(weekday),
                                  month_of_year: presence_int(month_of_year))
        return false if target == detect(recurring)

        write(recurring, target, reference)
        true
      end

      # Human-readable cadence, e.g. "Every 2 weeks on Friday".
      def label(recurring)
        found = detect(recurring)

        case found.key
        when "monthly"
          I18n.t("recurring_transactions.frequency.monthly", day: day_phrase(found.day_of_month))
        when "weekly"
          I18n.t("recurring_transactions.frequency.weekly", weekday: weekday_name(found.weekday))
        when "biweekly"
          I18n.t("recurring_transactions.frequency.biweekly", weekday: weekday_name(found.weekday))
        when "semimonthly"
          I18n.t("recurring_transactions.frequency.semimonthly",
                 first: day_phrase(found.day_of_month), second: day_phrase(found.second_day_of_month))
        when "quarterly"
          I18n.t("recurring_transactions.frequency.quarterly", day: day_phrase(found.day_of_month))
        when "semiannual"
          I18n.t("recurring_transactions.frequency.semiannual", day: day_phrase(found.day_of_month))
        when "annual"
          I18n.t("recurring_transactions.frequency.annual",
                 month: I18n.t("date.month_names")[found.month_of_year], day: day_phrase(found.day_of_month))
        else
          I18n.t("recurring_transactions.frequency.custom")
        end
      end

      private
        def detection(key:, day_of_month: nil, second_day_of_month: nil, weekday: nil, month_of_year: nil)
          Detection.new(key:, day_of_month:, second_day_of_month:, weekday:, month_of_year:)
        end

        def detect_single(rule)
          case rule.frequency
          when "weekly"
            case rule.interval
            when 1 then detection(key: "weekly", weekday: rule.weekday)
            when 2 then detection(key: "biweekly", weekday: rule.weekday)
            else detection(key: CUSTOM)
            end
          when "monthly"
            return detection(key: CUSTOM) unless rule.day_of_month.present?

            case rule.interval
            when 1 then detection(key: "monthly", day_of_month: rule.day_of_month)
            when 3 then detection(key: "quarterly", day_of_month: rule.day_of_month)
            when 6 then detection(key: "semiannual", day_of_month: rule.day_of_month)
            else detection(key: CUSTOM)
            end
          when "yearly"
            if rule.interval == 1 && rule.day_of_month.present?
              detection(key: "annual", day_of_month: rule.day_of_month, month_of_year: rule.month_of_year)
            else
              detection(key: CUSTOM)
            end
          end
        end

        def live_rules(recurring)
          recurring.recurrence_rules.reject(&:marked_for_destruction?)
        end

        # The Detection the submitted form values resolve to, with the same
        # defaulting write() will use, so equality against detect() is exact.
        def target_detection(recurring, reference, preset, day_of_month:, second_day_of_month:, weekday:, month_of_year:)
          case preset
          when "monthly", "quarterly", "semiannual"
            detection(key: preset, day_of_month: day_of_month || recurring.expected_day_of_month)
          when "weekly", "biweekly"
            detection(key: preset, weekday: weekday)
          when "semimonthly"
            days = canonical_semimonthly_days([ day_of_month || 1, second_day_of_month || 15 ])
            if days.uniq.size == 1
              detection(key: "monthly", day_of_month: days.first)
            else
              detection(key: preset, day_of_month: days.first, second_day_of_month: days.last)
            end
          when "annual"
            detection(key: preset, day_of_month: day_of_month || reference.day,
                      month_of_year: month_of_year || reference.month)
          end
        end

        def write(recurring, target, reference)
          recurring.rules_rewritten = true
          recurring.recurrence_rules.each(&:mark_for_destruction)

          case target.key
          when "monthly"
            build_rule(recurring, frequency: "monthly", day_of_month: target.day_of_month)
          when "weekly"
            build_rule(recurring, frequency: "weekly", weekday: target.weekday)
          when "biweekly"
            recurring.anchor_date ||= reference
            build_rule(recurring, frequency: "weekly", weekday: target.weekday, interval: 2)
          when "semimonthly"
            build_rule(recurring, frequency: "monthly", day_of_month: target.day_of_month)
            build_rule(recurring, frequency: "monthly", day_of_month: target.second_day_of_month, position: 1)
          when "quarterly"
            recurring.anchor_date ||= reference
            build_rule(recurring, frequency: "monthly", day_of_month: target.day_of_month, interval: 3)
          when "semiannual"
            recurring.anchor_date ||= reference
            build_rule(recurring, frequency: "monthly", day_of_month: target.day_of_month, interval: 6)
          when "annual"
            build_rule(recurring, frequency: "yearly", day_of_month: target.day_of_month,
                                  month_of_year: target.month_of_year)
          end

          recurring.expected_day_of_month = authoritative_day(target.key, target.day_of_month, reference)
        end

        # LAST sorts as the day it stands for, the end of the month, so
        # (15, LAST) and (LAST, 15) are one schedule. Without one canonical
        # order each reapply rewrote the rules instead of no-opping. Two equal
        # anchors are one monthly schedule, not a semimonthly pair.
        def canonical_semimonthly_days(days)
          days.sort_by { |day| day == RecurrenceRule::LAST ? 32 : day }
        end

        def monthly_day_rule?(rule)
          rule.frequency == "monthly" && rule.interval == 1 && rule.day_of_month.present?
        end

        def build_rule(recurring, position: 0, **attrs)
          recurring.recurrence_rules.build(position: position, **attrs)
        end

        # expected_day_of_month stays NOT NULL and authoritative for monthly
        # cadences; other cadences populate it but do not schedule from it.
        def authoritative_day(preset, day, reference)
          case preset
          when "monthly", "semimonthly", "quarterly", "semiannual", "annual"
            day == RecurrenceRule::LAST ? 31 : day
          else
            reference.day
          end
        end

        def presence_int(value)
          value.present? ? value.to_i : nil
        end

        def day_phrase(day)
          return I18n.t("recurring_transactions.frequency.last_day") if day == RecurrenceRule::LAST

          day.ordinalize
        end

        def weekday_name(weekday)
          I18n.t("date.day_names")[weekday]
        end
    end
  end
end
