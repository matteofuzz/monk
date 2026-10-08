require "json"

module Monk
  module Generator
    # What one `monk add` did, or would do: printed as text for a person
    # (decision 25), as one JSON object with --json (decision 27), and
    # turned into the exit code (decision 28) -- all from the same data.
    class Result
      EXIT_CODES = { ok: 0, usage_error: 1, missing_choice: 2, conflict: 3 }.freeze

      # The text form's widest path column.
      COLUMN = 30
      # The text form's numbered steps; JSON keeps them all.
      MAX_STEPS = 3

      attr_reader :status, :written, :dry_run, :requested, :modules, :files, :skipped, :env, :examples, :services,
        :next_steps, :docs, :closing, :message, :suggestion, :choice, :conflicts, :command

      def initialize(status:, written:, dry_run: false, requested: [], modules: [], files: [], skipped: [], env: [],
                     examples: [], services: [], next_steps: [], docs: [], closing: nil, message: nil, suggestion: nil,
                     choice: nil, conflicts: [], command: nil)
        @status = status
        @written = written
        @dry_run = dry_run
        @requested = requested
        @modules = modules
        @files = files
        @skipped = skipped
        @env = env
        @examples = examples
        @services = services
        @next_steps = next_steps
        @docs = docs
        @closing = closing
        @message = message
        @suggestion = suggestion
        @choice = choice
        @conflicts = conflicts
        @command = command
      end

      def ok? = status == :ok
      def exit_code = EXIT_CODES.fetch(status)

      def to_h
        hash = { status: status.to_s, written: written, requested: requested.map(&:to_s) }
        if ok?
          hash.merge!(
            modules: modules.map { |entry| stringify(entry) },
            files: files.map { |entry| file_json(entry) },
            skipped: skipped.map { |entry| stringify(entry) },
            env: env.map { |entry| stringify(entry.except(:module)) },
            examples: examples.map { |entry| stringify(entry.except(:module)) },
            services: services.map { |entry| stringify(entry) },
            next: next_steps.map { |entry| stringify(entry) },
            docs: docs,
          )
          hash[:dry_run] = true if dry_run
        else
          hash[:message] = message
          hash[:suggestion] = suggestion if suggestion
          hash[:choice] = stringify(choice.except(:describe, :command)) if choice
          hash[:conflicts] = conflicts.map { |entry| stringify(entry) } unless conflicts.empty?
        end
        stringify(hash)
      end

      def to_json(*) = JSON.pretty_generate(to_h)

      def to_text
        case status
        when :ok then ok_text
        when :missing_choice then missing_choice_text
        when :conflict then conflict_text
        else "#{message}#{"\n  #{suggestion}" if suggestion}\n\nNothing was written.\n"
        end
      end

      private

      def ok_text
        added = modules.select { |entry| entry[:action] == :added }
        if added.empty?
          return "#{names(requested)} #{requested.size > 1 ? "are" : "is"} already installed — nothing to do.\n"
        end

        lines = [header(added), ""]
        added.each do |entry|
          body = module_lines(entry[:name])
          lines << entry[:name].to_s if added.size > 1
          lines.concat(body)
          lines << "" if added.size > 1
        end
        lines.pop if lines.last == "" && added.size == 1
        sections = files.select { |entry| entry[:sections] }
        if sections.any?
          names = sections.flat_map { |entry| entry[:items] }.uniq
          label = names.size > 1 ? "sections" : "section"
          lines << row("~", sections.map { |entry| entry[:path] }.join(", "), "#{label}: #{names.join(", ")}")
        elsif lines.last == ""
          lines.pop
        end
        lines.concat(production_text, next_text)
        lines.push("", closing) if closing && !dry_run
        "#{lines.join("\n")}\n"
      end

      def header(added)
        to_add = added.reject { |entry| entry[:reason] }.map { |entry| entry[:name] }
        dependencies = added.select { |entry| entry[:reason] }.map { |entry| entry[:name] }
        installed = modules.select { |entry| entry[:action] == :already_installed }.map { |entry| entry[:name] }
        verb = dry_run ? "Would add" : "Adding"
        line = "#{verb} #{names(to_add)}"
        line += if dependencies.any?
                  ", which #{to_add.size > 1 ? "need" : "needs"} #{names(dependencies)} — adding " \
                    "#{dependencies.size > 1 ? "those" : "it"} first."
                elsif installed.any?
                  " (#{names(installed)} already installed)."
                else
                  "."
                end
        dry_run ? "#{line.chomp(".")} (nothing written):" : line
      end

      def module_lines(name)
        own = files.select { |entry| entry[:module] == name }
        created = own.select { |entry| entry[:action] == :created }
        lines = migrations_grouped(created).map { |entry| row("+", entry[:path], created_note(entry)) }
        lines += skipped.select { |entry| entry[:module] == name }.map do |entry|
          row("!", entry[:path], "exists and differs — left as is")
        end
        lines + appended_grouped(own.select { |entry| entry[:action] == :appended && !entry[:sections] })
      end

      def created_note(entry)
        return "example: #{entry[:examples].map(&:first).uniq.join(", ")} (commented)" if entry[:examples]&.any?

        "demo, development only" if entry[:role] == :demo
      end

      # db/migrate/..._name.up.sql and .down.sql as one line.
      def migrations_grouped(created)
        created.each_with_object([]) do |entry, rows|
          if entry[:path].end_with?(".down.sql") && rows.last && rows.last[:path] == entry[:path].sub(/\.down\.sql\z/,
            ".up.sql",)
            rows[-1] = rows.last.merge(path: entry[:path].sub(/\.down\.sql\z/, ".{up,down}.sql"))
          else
            rows << entry
          end
        end
      end

      # The files that got the same lines (the .env files, say), as one line.
      def appended_grouped(appended)
        appended.group_by { |entry| compact_keys(entry[:items]) }.map do |items, entries|
          row("~", entries.map { |entry| entry[:path] }.join(", "), items)
        end
      end

      # DB_HOST, DB_NAME... as DB_*.
      def compact_keys(items)
        prefix = items.first.to_s[/\A[A-Z]+_/]
        return "#{prefix}*" if prefix && items.size > 1 && items.all? { |item| item.start_with?(prefix) }

        items.join(", ")
      end

      def production_text
        return [] if env.empty?

        width = env.map { |entry| entry[:key].size }.max
        ["", "Set before production:", *env.map { |entry| "  #{entry[:key].ljust(width)}  #{entry[:note]}" }]
      end

      def next_text
        steps = next_steps.map { |step| step_text(step) }
        if steps.size >= 2 && steps[-2] == "bin/setup_db" && steps[-1].start_with?("bundle exec rake test")
          steps[-2..] = ["bin/setup_db && bundle exec rake test"]
        end
        steps = steps.first(MAX_STEPS - 1) + [steps.last, "… and the rest in SETUP.md"] if steps.size > MAX_STEPS
        numbered = steps.each_with_index.map do |step, index|
          step.start_with?("…") ? "  #{step}" : "  #{index + 1}. #{step}"
        end
        ["", "Next:", *numbered]
      end

      def step_text(step)
        step[:run] || step[:do]
      end

      def missing_choice_text
        lines = ["#{command}: #{message} Pass one:", ""]
        width = choice[:values].map(&:size).max
        choice[:values].each do |value|
          described = choice[:describe]&.fetch(value, nil)
          lines << "  #{command} --#{choice[:option]}=#{value.ljust(width)}#{"   #{described}" if described}"
        end
        "#{lines.join("\n")}\n\nNothing was written.\n"
      end

      def conflict_text
        lines = [message]
        conflicts.each { |entry| lines << "  Monk's version of #{entry[:path]}: #{entry[:show]}" }
        "#{lines.join("\n")}\n\nNothing was written.\n"
      end

      def row(mark, path, note = nil)
        note ? "  #{mark} #{path.ljust(COLUMN)} #{note}" : "  #{mark} #{path}"
      end

      def names(list)
        list = list.map(&:to_s)
        list.size <= 1 ? list.join : "#{list[0..-2].join(", ")} and #{list.last}"
      end

      def file_json(entry)
        json = entry.slice(:path, :module, :role, :action, :items)
        json[:examples] = entry[:examples].map(&:first).uniq if entry[:examples]&.any?
        json[:module] = nil if entry[:sections]
        stringify(json.compact)
      end

      def stringify(hash)
        hash.to_h { |key, value| [key.to_s, value.is_a?(Symbol) ? value.to_s : value] }
      end
    end
  end
end
