require_relative "errors"

module Monk
  module Jobs
    # A recurring task's schedule (docs/plan-scheduled-jobs.md decision 3):
    # five fields -- minute, hour, day of month, month, day of week -- each
    # `*`, numbers, lists (`,`), ranges (`-`) and steps (`/`), plus the
    # shortcuts in SHORTCUTS. No seconds, no names, no time zones: every
    # time is UTC.
    #
    # When both day fields are restricted, a day matching either counts; a
    # field starting with `*` (`*/2` too) doesn't restrict, as in Vixie
    # cron. Day of week 7 is Sunday, like 0.
    #
    # Frozen Arrays of Integers all the way down, so a parsed expression is
    # shareable with every Ractor.
    Cron = Data.define(:expression, :minutes, :hours, :days, :months, :weekdays, :any_day, :any_weekday)

    class Cron
      SHORTCUTS = {
        "@hourly" => "0 * * * *", "@daily" => "0 0 * * *", "@weekly" => "0 0 * * 0",
        "@monthly" => "0 0 1 * *", "@yearly" => "0 0 1 1 *",
      }.freeze

      FIELDS = [["minute", 0..59], ["hour", 0..23], ["day of month", 1..31], ["month", 1..12],
                ["day of week", 0..7],].freeze

      PART = %r{\A(\*|\d+(?:-\d+)?)(?:/(\d+))?\z}

      # The longest month each month can have: February counts its 29th.
      MONTH_DAYS = [nil, 31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31].freeze

      MINUTE = 60
      HOUR = 3600
      DAY = 86_400

      # Neither lookup can go further than this without having found an
      # occurrence: February 29th is at most 8 years away.
      MAX_YEARS = 9

      def self.parse(expression)
        unless expression.is_a?(String)
          raise InvalidCronError, "a cron expression is a String, got #{expression.inspect}"
        end

        normalized = expression.split.join(" ")
        fields = shortcut(normalized).split
        unless fields.size == 5
          raise InvalidCronError,
            "#{expression.inspect} has #{fields.size} field(s); a cron expression has 5 fields " \
            "(minute hour day-of-month month day-of-week) or is one of #{SHORTCUTS.keys.join(", ")}"
        end

        minutes, hours, days, months, weekdays = fields.zip(FIELDS).map do |text, (name, range)|
          parse_field(text, name, range, expression)
        end
        cron = new(
          expression: normalized.freeze, minutes:, hours:, days:, months:,
          weekdays: weekdays.map { |day| day % 7 }.uniq.sort.freeze,
          any_day: fields[2].start_with?("*"), any_weekday: fields[4].start_with?("*"),
        )
        cron.check_matches!
        Ractor.make_shareable(cron)
      end

      def self.shortcut(normalized)
        return normalized unless normalized.start_with?("@")

        SHORTCUTS.fetch(normalized) do
          raise InvalidCronError, "unknown cron shortcut #{normalized.inspect}; known: #{SHORTCUTS.keys.join(", ")}"
        end
      end

      def self.parse_field(text, name, range, expression)
        invalid = ->(problem) { raise InvalidCronError, "#{expression.inspect}: #{name} #{problem}" }

        text.split(",", -1).flat_map do |part|
          match = PART.match(part) || invalid.call("#{part.inspect} isn't a number, range or step")
          base, step = match.captures
          invalid.call("#{part.inspect}: a step goes on * or a range (a-b/n)") if step && !base.match?(/[*-]/)
          invalid.call("#{part.inspect}: the step is 0") if step&.to_i&.zero?

          from, to = base == "*" ? range.minmax : base.split("-").map(&:to_i).then { |a, b| [a, b || a] }
          [from, to].reject { |value| range.cover?(value) }.each do |value|
            invalid.call("#{value} is out of range (#{range.min}-#{range.max})")
          end
          invalid.call("range #{part.inspect} runs backwards") if from > to

          (from..to).step(step ? step.to_i : 1).to_a
        end.uniq.sort.freeze
      end
      private_class_method :shortcut, :parse_field

      def to_s = expression

      # The latest occurrence at or before `time`, as a UTC Time on a whole
      # minute. Steps field by field, so a yearly expression takes a handful
      # of steps, not a year of minutes.
      def previous(time)
        time = minute_of(time)
        limit = time.year - MAX_YEARS
        loop do
          raise InvalidCronError, "#{expression.inspect}: no occurrence found" if time.year < limit

          time =
            if !months.include?(time.month)
              month = months.rfind { |m| m < time.month }
              month ? end_of_month(time.year, month) : end_of_month(time.year - 1, months.last)
            elsif !day?(time)
              day_of(time) - MINUTE
            elsif !hours.include?(time.hour)
              hour = hours.rfind { |h| h < time.hour }
              hour ? day_of(time) + (hour * HOUR) + (59 * MINUTE) : day_of(time) - MINUTE
            elsif !minutes.include?(time.min)
              minute = minutes.rfind { |m| m < time.min }
              minute ? hour_of(time) + (minute * MINUTE) : hour_of(time) - MINUTE
            else
              return time
            end
        end
      end

      # The first occurrence after `time`, as a UTC Time on a whole minute.
      def next_after(time)
        time = minute_of(time) + MINUTE
        limit = time.year + MAX_YEARS
        loop do
          raise InvalidCronError, "#{expression.inspect}: no occurrence found" if time.year > limit

          time =
            if !months.include?(time.month)
              month = months.find { |m| m > time.month }
              month ? Time.utc(time.year, month) : Time.utc(time.year + 1, months.first)
            elsif !day?(time)
              day_of(time) + DAY
            elsif !hours.include?(time.hour)
              hour = hours.find { |h| h > time.hour }
              hour ? day_of(time) + (hour * HOUR) : day_of(time) + DAY
            elsif !minutes.include?(time.min)
              minute = minutes.find { |m| m > time.min }
              minute ? hour_of(time) + (minute * MINUTE) : hour_of(time) + HOUR
            else
              return time
            end
        end
      end

      # A day of month on its own (day of week *) must exist in one of the
      # months, or the expression never matches: `0 0 30 2 *`. With day of
      # week restricted, some week always has a matching day.
      def check_matches!
        return unless any_weekday && !any_day
        return if months.any? { |month| days.first <= MONTH_DAYS[month] }

        raise InvalidCronError, "#{expression.inspect} never matches: none of its months has day #{days.first}"
      end

      private

      def minute_of(time)
        utc = time.getutc
        Time.utc(utc.year, utc.month, utc.day, utc.hour, utc.min)
      end

      def day_of(time) = Time.utc(time.year, time.month, time.day)

      def hour_of(time) = Time.utc(time.year, time.month, time.day, time.hour)

      def end_of_month(year, month)
        (month == 12 ? Time.utc(year + 1, 1, 1) : Time.utc(year, month + 1, 1)) - MINUTE
      end

      def day?(time)
        in_month = days.include?(time.day)
        in_week = weekdays.include?(time.wday)
        any_day || any_weekday ? in_month && in_week : in_month || in_week
      end
    end
  end
end
