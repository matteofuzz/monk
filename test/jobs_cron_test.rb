require_relative "test_helper"
require "monk/jobs"
require "monk/jobs/cron"

# A recurring task's schedule: five cron fields, UTC only, and two pure
# lookups the scheduler builds on (docs/plan-scheduled-jobs.md decision 3,
# Phase 1). No database.
class JobsCronTest < Minitest::Test
  Cron = Monk::Jobs::Cron

  # -- parsing ---------------------------------------------------------------

  def test_every_field_form
    cron = Cron.parse("*/15 1-3,22 1,15 1-12/6 *")

    assert_equal [0, 15, 30, 45], cron.minutes
    assert_equal [1, 2, 3, 22], cron.hours
    assert_equal [1, 15], cron.days
    assert_equal [1, 7], cron.months
    assert_equal (0..6).to_a, cron.weekdays
  end

  def test_a_step_on_a_range
    assert_equal [10, 20, 30], Cron.parse("10-30/10 * * * *").minutes
  end

  def test_sunday_is_both_zero_and_seven
    assert_equal [0], Cron.parse("0 0 * * 7").weekdays
    assert_equal [0], Cron.parse("0 0 * * 0").weekdays
    assert_equal [0, 5, 6], Cron.parse("0 0 * * 5-7").weekdays
  end

  def test_shortcuts
    {
      "@hourly" => "0 * * * *", "@daily" => "0 0 * * *", "@weekly" => "0 0 * * 0",
      "@monthly" => "0 0 1 * *", "@yearly" => "0 0 1 1 *",
    }.each do |shortcut, fields|
      at = Time.utc(2026, 10, 12, 10, 30)

      assert_equal Cron.parse(fields).previous(at), Cron.parse(shortcut).previous(at), shortcut
      assert_equal Cron.parse(fields).next_after(at), Cron.parse(shortcut).next_after(at), shortcut
    end
  end

  # The expression is what monk_recurring_tasks stores to notice a changed
  # schedule (decision 8), so spacing alone doesn't count as a change.
  def test_the_expression_is_kept_with_its_spacing_normalized
    assert_equal "0 3 * * *", Cron.parse("  0  3 *\t* * ").expression
    assert_equal "@daily", Cron.parse("@daily").expression
  end

  def test_wrong_field_counts_are_rejected
    ["", "* * * *", "* * * * * *"].each do |expression|
      error = assert_raises(Monk::Jobs::InvalidCronError) { Cron.parse(expression) }
      assert_match(/5 fields/, error.message)
    end
  end

  def test_out_of_range_values_are_rejected_naming_the_field
    {
      "60 * * * *" => /minute.*0-59/, "* 24 * * *" => /hour.*0-23/, "* * 0 * *" => /day of month.*1-31/,
      "* * 32 * *" => /day of month/, "* * * 13 * " => /month.*1-12/, "* * * * 8" => /day of week.*0-7/,
      "1-70 * * * *" => /minute/,
    }.each do |expression, message|
      error = assert_raises(Monk::Jobs::InvalidCronError) { Cron.parse(expression) }
      assert_match message, error.message, expression
    end
  end

  def test_malformed_fields_are_rejected
    ["a * * * *", "5-1 * * * *", "*/0 * * * *", "5/10 * * * *", "1,,2 * * * *", "jan * * * *", "* * * jan *",
     "1-2-3 * * * *", "-1 * * * *",].each do |expression|
      assert_raises(Monk::Jobs::InvalidCronError, expression) { Cron.parse(expression) }
    end
  end

  def test_unknown_shortcuts_are_rejected_listing_the_known_ones
    error = assert_raises(Monk::Jobs::InvalidCronError) { Cron.parse("@every_5m") }

    assert_match(/@hourly/, error.message)
  end

  def test_only_a_string_is_an_expression
    assert_raises(Monk::Jobs::InvalidCronError) { Cron.parse(nil) }
    assert_raises(Monk::Jobs::InvalidCronError) { Cron.parse(:daily) }
  end

  def test_an_expression_that_never_matches_is_rejected
    ["0 0 30 2 *", "0 0 31 4,6,9,11 *"].each do |expression|
      error = assert_raises(Monk::Jobs::InvalidCronError) { Cron.parse(expression) }
      assert_match(/never/, error.message, expression)
    end
  end

  def test_february_29_and_day_31_are_accepted
    Cron.parse("0 0 29 2 *")
    Cron.parse("0 0 31 * *")
  end

  # -- previous / next_after -------------------------------------------------

  def test_previous_at_an_occurrence_is_that_occurrence
    cron = Cron.parse("0 3 * * *")

    assert_equal Time.utc(2026, 10, 12, 3, 0), cron.previous(Time.utc(2026, 10, 12, 3, 0))
    assert_equal Time.utc(2026, 10, 12, 3, 0), cron.previous(Time.utc(2026, 10, 12, 3, 0, 59.9))
  end

  def test_previous_between_occurrences
    cron = Cron.parse("0 3 * * *")

    assert_equal Time.utc(2026, 10, 12, 3, 0), cron.previous(Time.utc(2026, 10, 12, 17, 45))
    assert_equal Time.utc(2026, 10, 11, 3, 0), cron.previous(Time.utc(2026, 10, 12, 2, 59, 59))
  end

  def test_next_after_an_occurrence_is_the_one_after
    cron = Cron.parse("*/15 * * * *")

    assert_equal Time.utc(2026, 10, 12, 10, 15), cron.next_after(Time.utc(2026, 10, 12, 10, 0))
    assert_equal Time.utc(2026, 10, 12, 10, 15), cron.next_after(Time.utc(2026, 10, 12, 10, 0, 30))
  end

  def test_next_after_between_occurrences
    cron = Cron.parse("0 9 * * 1")

    assert_equal Time.utc(2026, 10, 12, 9, 0), cron.next_after(Time.utc(2026, 10, 10, 12, 0))
    assert_equal Time.utc(2026, 10, 19, 9, 0), cron.next_after(Time.utc(2026, 10, 12, 9, 0))
  end

  def test_across_month_and_year_boundaries
    monthly = Cron.parse("0 0 1 * *")
    last_minute = Cron.parse("59 23 * * *")

    assert_equal Time.utc(2027, 1, 1), monthly.next_after(Time.utc(2026, 12, 31, 23, 59))
    assert_equal Time.utc(2026, 12, 1), monthly.previous(Time.utc(2026, 12, 31, 23, 59))
    assert_equal Time.utc(2026, 12, 31, 23, 59), last_minute.previous(Time.utc(2027, 1, 1, 0, 0))
    assert_equal Time.utc(2027, 2, 28, 23, 59), last_minute.previous(Time.utc(2027, 3, 1))
    assert_equal Time.utc(2028, 2, 29, 23, 59), last_minute.previous(Time.utc(2028, 3, 1))
  end

  def test_february_29_is_found_across_years
    cron = Cron.parse("0 0 29 2 *")

    assert_equal Time.utc(2028, 2, 29), cron.next_after(Time.utc(2026, 3, 1))
    assert_equal Time.utc(2024, 2, 29), cron.previous(Time.utc(2027, 6, 1))
  end

  # 2100 isn't a leap year: the longest gap there is, eight years.
  def test_february_29_across_a_century
    cron = Cron.parse("0 0 29 2 *")

    assert_equal Time.utc(2104, 2, 29), cron.next_after(Time.utc(2096, 3, 1))
    assert_equal Time.utc(2096, 2, 29), cron.previous(Time.utc(2104, 2, 28))
  end

  def test_day_31_skips_the_short_months
    cron = Cron.parse("0 0 31 * *")

    assert_equal Time.utc(2026, 12, 31), cron.next_after(Time.utc(2026, 10, 31))
    assert_equal Time.utc(2026, 8, 31), cron.previous(Time.utc(2026, 10, 30))
  end

  # As in Vixie cron: with both day fields restricted a day matching either
  # counts; with one of them * only the other one decides.
  def test_both_day_fields_restricted_match_either
    cron = Cron.parse("0 0 13 * 5") # the 13th, and every Friday

    assert_equal Time.utc(2026, 10, 13), cron.next_after(Time.utc(2026, 10, 12))
    assert_equal Time.utc(2026, 10, 16), cron.next_after(Time.utc(2026, 10, 13))
  end

  def test_one_day_field_restricted_decides_alone
    assert_equal Time.utc(2026, 11, 13), Cron.parse("0 0 13 * *").next_after(Time.utc(2026, 10, 13))
    assert_equal Time.utc(2026, 10, 16), Cron.parse("0 0 * * 5").next_after(Time.utc(2026, 10, 13))
  end

  # Vixie cron treats a field starting with * as unrestricted, steps
  # included: "*/2" days of month and Mondays means Mondays on odd days.
  def test_a_starred_step_counts_as_unrestricted
    cron = Cron.parse("0 0 */2 * 1")

    assert_equal Time.utc(2026, 10, 19), cron.next_after(Time.utc(2026, 10, 12))
  end

  def test_times_in_other_zones_are_read_as_utc
    cron = Cron.parse("0 3 * * *")
    rome = Time.new(2026, 10, 12, 5, 30, 0, "+02:00") # 03:30 UTC

    assert_equal Time.utc(2026, 10, 12, 3, 0), cron.previous(rome)
    assert_equal Time.utc(2026, 10, 13, 3, 0), cron.next_after(rome)
    assert_predicate cron.previous(rome), :utc?
  end

  def test_results_are_whole_utc_minutes
    at = Cron.parse("* * * * *").previous(Time.utc(2026, 10, 12, 10, 30, 42.5))

    assert_equal Time.utc(2026, 10, 12, 10, 30), at
    assert_equal 0, at.sec
    assert_equal 0, at.subsec
  end

  def test_every_minute
    cron = Cron.parse("* * * * *")

    assert_equal Time.utc(2026, 12, 31, 23, 59), cron.previous(Time.utc(2026, 12, 31, 23, 59, 30))
    assert_equal Time.utc(2027, 1, 1), cron.next_after(Time.utc(2026, 12, 31, 23, 59, 30))
  end

  # The field-by-field lookups agree with checking every minute, one by
  # one, from random starting points.
  def test_lookups_agree_with_a_minute_by_minute_scan
    random = Random.new(20_261_012)
    ["*/7 * * * *", "5,35 */3 * * *", "0 9-17 * * 1-5", "30 2 */2 * *", "0 0 13 * 5", "15 4 * * 0,6",
     "0 12 1,15 * *", "45 23 * * 7", "0 0 */5 * 3",].each do |expression|
      cron = Cron.parse(expression)
      5.times do
        at = Time.utc(2026, 1, 1) + random.rand(3 * 365 * Cron::DAY)

        assert_equal scan(cron, at, -60), cron.previous(at), "#{expression} previous(#{at})"
        assert_equal scan(cron, at, 60), cron.next_after(at), "#{expression} next_after(#{at})"
      end
    end
  end

  # -- Ractors ----------------------------------------------------------------

  def test_a_parsed_expression_is_shareable
    cron = Cron.parse("0 9 * * 1")

    assert Ractor.shareable?(cron)
    assert_equal Time.utc(2026, 10, 12, 9, 0), Ractor.new(cron) { |c| c.next_after(Time.utc(2026, 10, 10)) }.value
  end

  private

  # The first minute matching `cron` stepping from `at` by `step` seconds:
  # previous includes `at`'s own minute, next_after starts after it.
  # Matches with the fields and Vixie's day rule, written out again.
  def scan(cron, at, step)
    t = Time.utc(at.year, at.month, at.day, at.hour, at.min)
    t += step if step.positive?
    t += step until matches?(cron, t)
    t
  end

  def matches?(cron, time)
    in_month = cron.days.include?(time.day)
    in_week = cron.weekdays.include?(time.wday)
    day = cron.any_day || cron.any_weekday ? in_month && in_week : in_month || in_week
    cron.minutes.include?(time.min) && cron.hours.include?(time.hour) && cron.months.include?(time.month) && day
  end
end
