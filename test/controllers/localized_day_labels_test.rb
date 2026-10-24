require "test_helper"

class LocalizedDayLabelsTest < ActionDispatch::IntegrationTest
  SAMPLE_DAYS = [ 1, 2, 3, 4, 11, 12, 13, 21, 28, 31 ].freeze
  ENGLISH_LABELS = %w[1st 2nd 3rd 4th 11th 12th 13th 21st 28th 31st].freeze
  CATALAN_LABELS = %w[1r 2n 3r 4t 11è 12è 13è 21è 28è 31è].freeze
  ENGLISH_SUFFIX = /\b\d+(?:st|nd|rd|th)\b/

  setup do
    user = users(:family_admin)
    user.update!(preferences: (user.preferences || {}).merge("preview_features_enabled" => true))
    sign_in user
    ensure_tailwind_build
  end

  LanguagesHelper::SUPPORTED_LOCALES.each do |locale|
    test "#{locale} renders localized days in the actual preferences and recurrence forms" do
      get settings_preferences_url(locale: locale)
      assert_response :success
      assert_select "select[name='user[family_attributes][month_start_day]']" do
        assert_select "option", count: 28
        SAMPLE_DAYS.select { |day| day <= 28 }.each do |day|
          assert_select "option[value='#{day}']", text: expected_picker_day(locale, day)
        end
      end

      get edit_recurring_transaction_url(recurring_transactions(:netflix_subscription), locale: locale),
          headers: { "Turbo-Frame" => "modal" }
      assert_response :success
      %w[frequency_day_of_month frequency_second_day_of_month].each do |field|
        assert_select "select[name='recurring_transaction[#{field}]']" do
          assert_select "option", count: 32
          SAMPLE_DAYS.each do |day|
            assert_select "option[value='#{day}']", text: expected_picker_day(locale, day)
          end
          assert_select "option[value='-1']",
                        text: I18n.t("recurring_transactions.frequency.last_day", locale: locale, raise: true)
        end
      end
    end

    test "#{locale} renders cadence dates without leaking English suffixes or changing rules" do
      I18n.with_locale(locale) do
        shapes = [
          [ { frequency: "monthly", interval: 1 } ],
          [ { frequency: "monthly", interval: 3 } ],
          [ { frequency: "monthly", interval: 6 } ],
          [ { frequency: "yearly", interval: 1, month_of_year: 1 } ],
          [ { frequency: "monthly", interval: 2 } ],
          [ { frequency: "yearly", interval: 2, month_of_year: 1 } ]
        ]

        shapes.each do |rules|
          [ 1, 2, 21, 31, RecurrenceRule::LAST ].each do |day|
            series = build_series(rules, day: day)
            before = series.recurrence_rules.map(&:attributes)
            label = RecurringTransaction::FrequencyPreset.label(series)
            assert label.present?, "#{locale}: empty cadence"
            assert_no_match(/translation missing|\.{2}|日\s*日|tháng\s+tháng/i, label)
            assert_no_match ENGLISH_SUFFIX, label unless locale == "en"
            expected_day = if day == RecurrenceRule::LAST
              I18n.t("recurring_transactions.frequency.last_day", raise: true)
            elsif locale == "en"
              day.ordinalize
            else
              I18n.t("date.day_of_month", day: day, fallback: false, raise: true)
            end
            assert_includes label, expected_day
            assert_equal before, series.recurrence_rules.map(&:attributes)
            assert series.new_record?
          end
        end

        twice_monthly = build_series([
          { frequency: "monthly", interval: 1, day_of_month: 1 },
          { frequency: "monthly", interval: 1, day_of_month: 15 }
        ])
        label = RecurringTransaction::FrequencyPreset.label(twice_monthly)
        assert_no_match ENGLISH_SUFFIX, label unless locale == "en"
        assert_no_match(/\.{2}|日\s*日/, label)
      end
    end
  end

  test "German dates have one ordinal dot and Vietnamese month names are not prefixed twice" do
    annual = build_series([ { frequency: "yearly", interval: 1, month_of_year: 1 } ], day: 2)
    two_yearly = build_series([ { frequency: "yearly", interval: 2, month_of_year: 1 } ], day: 2)
    I18n.with_locale(:de) do
      assert_equal "Jährlich am 2. Januar", RecurringTransaction::FrequencyPreset.label(annual)
      assert_equal "Alle 2 Jahre am 2. Januar", RecurringTransaction::FrequencyPreset.label(two_yearly)
    end
    I18n.with_locale(:vi) do
      assert_equal "Hằng năm vào ngày 2, Tháng một", RecurringTransaction::FrequencyPreset.label(annual)
      assert_equal "Mỗi 2 năm vào ngày 2, Tháng một", RecurringTransaction::FrequencyPreset.label(two_yearly)
    end
  end

  test "Hungarian cadence labels accommodate numeric days and the last day without repeated day words" do
    I18n.with_locale(:hu) do
      monthly = build_series([ { frequency: "monthly", interval: 1 } ], day: 2)
      monthly_last = build_series([ { frequency: "monthly", interval: 1 } ], day: RecurrenceRule::LAST)
      annual = build_series([ { frequency: "yearly", interval: 1, month_of_year: 1 } ], day: 2)
      annual_last = build_series([ { frequency: "yearly", interval: 1, month_of_year: 1 } ], day: RecurrenceRule::LAST)
      twice_monthly = build_series([
        { frequency: "monthly", interval: 1, day_of_month: 15 },
        { frequency: "monthly", interval: 1, day_of_month: RecurrenceRule::LAST }
      ])
      assert_equal "Havonta, nap: 2", RecurringTransaction::FrequencyPreset.label(monthly)
      assert_equal "Havonta, nap: utolsó nap", RecurringTransaction::FrequencyPreset.label(monthly_last)
      assert_equal "Évente, hónap: január, nap: 2", RecurringTransaction::FrequencyPreset.label(annual)
      assert_equal "Évente, hónap: január, nap: utolsó nap", RecurringTransaction::FrequencyPreset.label(annual_last)
      assert_equal "Havonta kétszer, napok: 15 és utolsó nap", RecurringTransaction::FrequencyPreset.label(twice_monthly)
      assert_equal "utolsó nap", I18n.t("recurring_transactions.frequency.last_day")
    end
  end

  test "Spanish monthly labels include numeric days and last day without a repeated day word" do
    I18n.with_locale(:es) do
      { 1 => "Cada mes", 3 => "Cada trimestre", 6 => "Cada 6 meses", 2 => "Cada 2 meses" }.each do |interval, prefix|
        numeric = build_series([ { frequency: "monthly", interval: interval } ], day: 2)
        last = build_series([ { frequency: "monthly", interval: interval } ], day: RecurrenceRule::LAST)
        assert_equal "#{prefix}, el 2", RecurringTransaction::FrequencyPreset.label(numeric)
        assert_equal "#{prefix}, el último día", RecurringTransaction::FrequencyPreset.label(last)
      end
      assert_equal "último día", I18n.t("recurring_transactions.frequency.last_day")
    end
  end

  test "localized monthly date labels work with numbers and last day without duplicated day wording" do
    cases = {
      "nl" => { last: "laatste dag", labels: { 1 => "Maandelijks, dag:", 3 => "Elk kwartaal, dag:", 6 => "Elke 6 maanden, dag:", 2 => "Elke 2 maanden, dag:" } },
      "ro" => { last: "ultima zi", labels: { 1 => "Lunar, zi:", 3 => "Trimestrial, zi:", 6 => "La fiecare 6 luni, zi:", 2 => "La fiecare 2 luni, zi:" } },
      "pl" => { last: "ostatni dzień", labels: { 1 => "Co miesiąc, dzień:", 3 => "Co kwartał, dzień:", 6 => "Co 6 miesięcy, dzień:", 2 => "Co 2 mies., dzień:" } },
      "pt-BR" => { last: "último dia", labels: { 1 => "Mensalmente, dia:", 3 => "Trimestralmente, dia:", 6 => "A cada 6 meses, dia:", 2 => "A cada 2 meses, dia:" } },
      "pt-PT" => { last: "último dia", labels: { 1 => "Mensalmente, dia:", 3 => "Trimestralmente, dia:", 6 => "A cada 6 meses, dia:", 2 => "A cada 2 meses, dia:" } },
      "ca" => { last: "darrer dia", labels: { 2 => "Cada 2 mesos, el" } }
    }
    cases.each do |locale, expected|
      I18n.with_locale(locale) do
        expected[:labels].each do |interval, prefix|
          numeric = build_series([ { frequency: "monthly", interval: interval } ], day: 2)
          last = build_series([ { frequency: "monthly", interval: interval } ], day: RecurrenceRule::LAST)
          assert_equal "#{prefix} 2", RecurringTransaction::FrequencyPreset.label(numeric)
          assert_equal "#{prefix} #{expected[:last]}", RecurringTransaction::FrequencyPreset.label(last)
        end
        assert_equal expected[:last], I18n.t("recurring_transactions.frequency.last_day")
      end
    end

    twice_monthly = build_series([
      { frequency: "monthly", interval: 1, day_of_month: 15 },
      { frequency: "monthly", interval: 1, day_of_month: RecurrenceRule::LAST }
    ])
    I18n.with_locale(:nl) do
      assert_equal "Tweemaal per maand, dagen: 15 en laatste dag", RecurringTransaction::FrequencyPreset.label(twice_monthly)
    end
    I18n.with_locale(:pl) do
      assert_equal "Dwa razy w miesiącu, dni: 15 i ostatni dzień", RecurringTransaction::FrequencyPreset.label(twice_monthly)
    end
  end

  test "English and Catalan picker ordinals and existing Chinese and Norwegian day formats remain intact" do
    %w[en ca nb zh-CN zh-TW].each do |locale|
      I18n.with_locale(locale) do
        SAMPLE_DAYS.each do |day|
          assert_equal expected_picker_day(locale, day), ApplicationController.helpers.localized_ordinal(day)
        end
      end
    end
    I18n.with_locale(:ca) do
      assert_equal "Cada mes, el 1", RecurringTransaction::FrequencyPreset.label(build_series([], day: 1))
      assert_equal "1r", ApplicationController.helpers.localized_ordinal(1)
    end
  end

  private
    def expected_picker_day(locale, day)
      case locale
      when "en" then ENGLISH_LABELS.fetch(SAMPLE_DAYS.index(day))
      when "ca" then CATALAN_LABELS.fetch(SAMPLE_DAYS.index(day))
      when "de", "nb" then "#{day}."
      when "zh-CN", "zh-TW" then "#{day}日"
      else day.to_s
      end
    end

    def build_series(rules, day: 1)
      RecurringTransaction.new(expected_day_of_month: day).tap do |series|
        rules.each_with_index do |rule, position|
          series.recurrence_rules.build({ day_of_month: day, position: position }.merge(rule))
        end
      end
    end
end
