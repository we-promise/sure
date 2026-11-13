class RecurringTransaction
  # Translates between the frequency picker's presets and recurrence_rules
  # rows. A preset is a named rule shape (biweekly = one weekly rule with
  # interval 2); anything the picker cannot express reads back as CUSTOM and
  # is left untouched.
  class FrequencyPreset
    # "once" is one occurrence on a date. It is stored as a yearly rule capped
    # at a single payment, so the schedule engine can place it without a new
    # frequency value. Listed with the named presets so the picker and the
    # assistant offer the same set.
    ONCE = "once"
    PRESETS = %w[once monthly weekly biweekly semimonthly quarterly semiannual annual].freeze
    CUSTOM = "custom"

    # "Every N weeks, months or years": one rule of any interval, for the
    # cadences no named preset covers. Kept out of PRESETS, which the AI tools
    # publish as their frequency enum and which carries no interval.
    INTERVAL = "interval"
    INTERVAL_UNITS = %w[weekly monthly yearly].freeze
    MAX_INTERVAL = 99

    Detection = Data.define(:key, :day_of_month, :second_day_of_month, :weekday, :month_of_year,
                            :interval, :interval_unit, :once_on)

    class << self
      # Reads the series' rules back into picker values. Zero rules is the
      # legacy implicit monthly.
      def detect(recurring)
        rules = live_rules(recurring)

        if once_schedule?(recurring, rules)
          rule = rules.first
          return detection(key: ONCE, once_on: recurring.anchor_date || recurring.next_expected_date,
                           day_of_month: rule.day_of_month, month_of_year: rule.month_of_year)
        end

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
      #
      # An out-of-range interval or unknown unit is reported on the record and
      # rewrites nothing; callers check errors before saving.
      def apply(recurring, preset:, day_of_month: nil, second_day_of_month: nil, weekday: nil, month_of_year: nil,
                interval: nil, interval_unit: nil, once_on: nil)
        return false if preset.blank? || preset == CUSTOM
        return false unless PRESETS.include?(preset) || preset == INTERVAL

        interval = strict_int(interval)
        if preset == INTERVAL && !valid_interval?(interval, interval_unit)
          recurring.errors.add(:frequency_interval, :invalid)
          return false
        end

        was_once = once_schedule?(recurring)
        once_date = nil
        if preset == ONCE
          once_date = resolve_once_date(recurring, once_on, was_once)
          if once_date.nil?
            recurring.errors.add(:base, I18n.t("recurring_transactions.create.due_date_required"))
            return false
          end

          # A paid one-off is that payment. Moving the date would keep the
          # paid row and generate a second, open one, so the change is refused.
          if was_once && once_date != current_once_date(recurring) &&
             settled_occurrence?(recurring, current_once_date(recurring))
            recurring.errors.add(:base, I18n.t("recurring_transactions.update.once_date_locked"))
            return false
          end
        end

        reference = recurring.anchor_date || recurring.last_occurrence_date || Date.current
        target = target_detection(recurring, reference, preset,
                                  day_of_month: presence_int(day_of_month),
                                  second_day_of_month: presence_int(second_day_of_month),
                                  weekday: presence_int(weekday),
                                  month_of_year: presence_int(month_of_year),
                                  interval: interval,
                                  interval_unit: interval_unit,
                                  once_on: once_date)
        return false if target == detect(recurring)

        write(recurring, target, reference)
        # Leaving "once" must drop the one-payment cap, or the next cadence
        # would also end after a single occurrence. An installment owns that
        # cap itself, so its count stays.
        release_once_end(recurring) if was_once && preset != ONCE && !recurring.typed_installment?
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
        when ONCE
          if found.once_on
            I18n.t("recurring_transactions.frequency.once_on", date: I18n.l(found.once_on, format: :long))
          else
            I18n.t("recurring_transactions.frequency.once")
          end
        when INTERVAL
          interval_label(found)
        else
          I18n.t("recurring_transactions.frequency.custom")
        end
      end

      private
        def detection(key:, day_of_month: nil, second_day_of_month: nil, weekday: nil, month_of_year: nil,
                      interval: nil, interval_unit: nil, once_on: nil)
          Detection.new(key:, day_of_month:, second_day_of_month:, weekday:, month_of_year:, interval:, interval_unit:,
                        once_on:)
        end

        # A one-payment yearly rule that is not an installment. Installments
        # carry their own count, so a one-payment plan stays an installment.
        def once_schedule?(recurring, rules = live_rules(recurring))
          return false if recurring.typed_installment?
          return false unless recurring.end_mode == "after_count" && recurring.end_after_count == 1
          return false unless rules.size == 1

          rule = rules.first
          rule.frequency == "yearly" && rule.interval == 1 && rule.day_of_month.present? && rule.weekday.blank?
        end

        def current_once_date(recurring)
          recurring.anchor_date || recurring.next_expected_date
        end

        # Whether the occurrence on `date` is closed or carries an allocation,
        # a payment the generator will not delete. Only that date: rows left by
        # an earlier repeating schedule say nothing about the one-off.
        def settled_occurrence?(recurring, date)
          occurrences = recurring.recurring_occurrences.where(original_due_on: date)
          occurrences.closed.exists? ||
            RecurringAllocation.where(recurring_occurrence_id: occurrences.select(:id)).exists?
        end

        # A blank date keeps an existing one-off where it is. Anything else
        # becomes due on what the bill currently shows as its due date: the
        # anchor is its first due date and stays put as occurrences advance, so
        # it can be months behind. A date that was typed but cannot be parsed
        # is refused, rather than quietly kept.
        def resolve_once_date(recurring, once_on, was_once)
          return nil if once_on.present? && strict_date(once_on).nil?

          strict_date(once_on) ||
            (current_once_date(recurring) if was_once || !recurring.persisted?) ||
            recurring.next_due_date
        end

        def strict_date(value)
          return value if value.is_a?(Date)
          return nil if value.blank?

          Date.iso8601(value.to_s)
        rescue Date::Error
          nil
        end

        def release_once_end(recurring)
          recurring.end_mode = "never"
          recurring.end_after_count = nil
          recurring.end_on = nil
        end

        # Monthly and yearly rules anchored on an nth weekday ("3rd Friday")
        # have no picker shape.
        def detect_single(rule)
          return detection(key: CUSTOM) if rule.frequency != "weekly" && rule.day_of_month.blank?

          every(rule.frequency, rule.interval, day_of_month: rule.day_of_month,
                weekday: rule.weekday, month_of_year: rule.month_of_year)
        end

        # One rule of `interval` units, read as the named preset it is when one
        # exists, so "every 3 months" and "quarterly" are the same schedule
        # whichever way it was entered, and reapplying either is a no-op.
        def every(unit, interval, day_of_month:, weekday:, month_of_year:)
          case [ unit, interval ]
          when [ "weekly", 1 ]  then detection(key: "weekly", weekday: weekday)
          when [ "weekly", 2 ]  then detection(key: "biweekly", weekday: weekday)
          when [ "monthly", 1 ] then detection(key: "monthly", day_of_month: day_of_month)
          when [ "monthly", 3 ] then detection(key: "quarterly", day_of_month: day_of_month)
          when [ "monthly", 6 ] then detection(key: "semiannual", day_of_month: day_of_month)
          when [ "yearly", 1 ]  then detection(key: "annual", day_of_month: day_of_month, month_of_year: month_of_year)
          else
            detection(key: INTERVAL, interval: interval, interval_unit: unit,
                      weekday: (weekday if unit == "weekly"),
                      day_of_month: (day_of_month unless unit == "weekly"),
                      month_of_year: (month_of_year if unit == "yearly"))
          end
        end

        def valid_interval?(interval, unit)
          INTERVAL_UNITS.include?(unit) && interval.present? && interval.between?(1, MAX_INTERVAL)
        end

        def live_rules(recurring)
          recurring.recurrence_rules.reject(&:marked_for_destruction?)
        end

        # The Detection the submitted form values resolve to, with the same
        # defaulting write() will use, so equality against detect() is exact.
        def target_detection(recurring, reference, preset, day_of_month:, second_day_of_month:, weekday:, month_of_year:,
                             interval:, interval_unit:, once_on:)
          case preset
          when ONCE
            detection(key: ONCE, once_on: once_on, day_of_month: once_on.day, month_of_year: once_on.month)
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
          when INTERVAL
            every(interval_unit, interval,
                  day_of_month: day_of_month || (interval_unit == "yearly" ? reference.day : recurring.expected_day_of_month),
                  weekday: weekday || reference.wday,
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
          when ONCE
            # The anchor is the only due date. next_expected_date is the hint
            # the bills list reads, so it has to move with that date.
            recurring.anchor_date = target.once_on
            recurring.next_expected_date = target.once_on
            recurring.end_mode = "after_count"
            recurring.end_after_count = 1
            recurring.end_on = nil
            build_rule(recurring, frequency: "yearly", day_of_month: target.day_of_month,
                                  month_of_year: target.month_of_year)
          when INTERVAL
            recurring.anchor_date ||= reference
            build_rule(recurring, frequency: target.interval_unit, interval: target.interval,
                                  day_of_month: target.day_of_month, weekday: target.weekday,
                                  month_of_year: target.month_of_year)
          end

          recurring.expected_day_of_month = authoritative_day(target, reference)
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
        def authoritative_day(target, reference)
          day_anchored = case target.key
          when "monthly", "semimonthly", "quarterly", "semiannual", "annual", ONCE then true
          when INTERVAL then target.interval_unit != "weekly"
          else false
          end

          return reference.day unless day_anchored

          target.day_of_month == RecurrenceRule::LAST ? 31 : target.day_of_month
        end

        def presence_int(value)
          value.present? ? value.to_i : nil
        end

        # The interval is typed, not picked from a list, so it is parsed whole:
        # to_i would read "2.5" as 2 and "3abc" as 3 and save a cadence nobody
        # asked for. Base 10 because Integer alone reads "010" as octal.
        def strict_int(value)
          return value if value.is_a?(Integer)
          return nil if value.blank?

          Integer(value.to_s, 10, exception: false)
        end

        def day_phrase(day)
          return I18n.t("recurring_transactions.frequency.last_day") if day == RecurrenceRule::LAST

          day.ordinalize
        end

        def weekday_name(weekday)
          I18n.t("date.day_names")[weekday]
        end

        def interval_label(found)
          case found.interval_unit
          when "weekly"
            I18n.t("recurring_transactions.frequency.every_n_weeks",
                   interval: found.interval, weekday: weekday_name(found.weekday))
          when "monthly"
            I18n.t("recurring_transactions.frequency.every_n_months",
                   interval: found.interval, day: day_phrase(found.day_of_month))
          when "yearly"
            I18n.t("recurring_transactions.frequency.every_n_years",
                   interval: found.interval, month: I18n.t("date.month_names")[found.month_of_year],
                   day: day_phrase(found.day_of_month))
          end
        end
    end
  end
end
