require "fileutils"

module Monk
  module Generator
    # One `monk add`: works out every module to add (dependencies first,
    # options inferred or missing), checks every file against the app,
    # and only then writes -- or writes nothing, on a usage error, a missing
    # choice, a conflict on a wiring file, or a dry run
    # (docs/plan-scaffold.md decisions 2-5, 25-28).
    class Run
      # A choice the user has to make before anything can be planned.
      MissingChoice = Class.new(StandardError) do
        attr_reader :choice

        def initialize(choice)
          @choice = choice
          super(choice[:message])
        end
      end

      UsageError = Class.new(StandardError) do
        attr_reader :suggestion

        def initialize(message, suggestion: nil)
          @suggestion = suggestion
          super(message)
        end
      end

      def initialize(registry:, dir:, requested:, options: {}, dry_run: false, now: Time.now, command: nil)
        @registry = registry
        @dir = File.expand_path(dir)
        @requested = requested.map(&:to_sym)
        @options = options.transform_keys(&:to_sym).transform_values(&:to_s)
        @dry_run = dry_run
        @now = now
        @command = command || "monk add #{@requested.join(" ")}"
      end

      def call
        validate!
        @installed = @registry.definitions.select { |definition| installed?(definition) }.map(&:name)
        @plan = resolve
        @files = Files.new(@dir)
        @migration_count = 0
        entries = @plan.flat_map { |definition, options| entries_for(definition, options) }
        conflicts = entries.select { |entry| entry[:action] == :conflict && entry[:role] == :wiring }
        return conflict_result(conflicts) unless conflicts.empty?

        result(entries)
      rescue UsageError => e
        error_result(:usage_error, e.message, suggestion: e.suggestion)
      rescue MissingChoice => e
        error_result(:missing_choice, e.message, choice: e.choice.except(:message))
      end

      private

      def validate!
        raise UsageError.new("Nothing to add.", suggestion: "monk add --list") if @requested.empty?

        unknown = @requested - @registry.names
        unless unknown.empty?
          raise UsageError.new(
            "Unknown module#{"s" if unknown.size > 1}: #{unknown.join(", ")}. Modules: #{@registry.names.join(", ")}.",
            suggestion: "monk add --list",
          )
        end

        @registry.definitions.flat_map(&:options).each do |option|
          value = @options[option.name]
          next if value.nil? || option.values.include?(value)

          raise UsageError, "--#{option.name}=#{value} isn't one of #{option.values.join(", ")}."
        end
      end

      def installed?(definition)
        File.exist?(File.join(@dir, definition.installed_if))
      end

      # [definition, options] for every module to add, dependencies first.
      # Options are inferred from the modules installed or being added in
      # this same command (decision 13), so `--with jobs,live` picks
      # Postgres for websocket's transport.
      def resolve
        available = (@installed + static_closure).map(&:to_s)
        plan = []
        visiting = []
        visit = lambda do |name, needed_by|
          @needed_by[name] |= [needed_by] if needed_by
          return if @installed.include?(name) || plan.any? { |definition, _| definition.name == name }
          raise UsageError, "Modules depend on each other in a cycle: #{(visiting + [name]).join(" -> ")}." if
            visiting.include?(name)

          definition = @registry.fetch(name)
          options = resolve_options(definition, available)
          visiting.push(name)
          definition.dependencies(options).each { |dependency| visit.call(dependency, name) }
          visiting.pop
          plan << [definition, options]
        end
        @needed_by = Hash.new { |hash, key| hash[key] = [] }
        @requested.each { |name| visit.call(name, nil) }
        plan
      end

      def static_closure
        seen = []
        queue = @requested.dup
        until queue.empty?
          name = queue.shift
          next if seen.include?(name)

          seen << name
          queue.concat(@registry.fetch(name).dependencies)
        end
        seen
      end

      def resolve_options(definition, available)
        definition.options.to_h do |option|
          given = @options[option.name]
          next [option.name, given] if given

          candidates = option.infer_from & available
          next [option.name, candidates.first] if candidates.size == 1

          raise MissingChoice, missing_choice(definition, option, candidates)
        end
      end

      def missing_choice(definition, option, candidates)
        reason = if candidates.empty?
                   "this app has none of #{option.infer_from.join(", ")}"
                 else
                   "this app has both #{candidates.join(" and ")}"
                 end
        {
          module: definition.name.to_s, option: option.name.to_s, values: option.values, reason: reason,
          describe: option.describe, command: @command,
          message: "#{definition.name} needs a #{option.name}, and #{reason}.",
        }
      end

      def entries_for(definition, options)
        entries = definition.copies.map { |copy| copy_entry(definition, copy, options) }
        entries.concat(definition.migrations.flat_map { |migration| migration_entries(definition, migration) })
        entries.concat(gem_entries(definition))
        entries.concat(env_entries(definition))
        entries.concat(ignore_entries(definition))
        entries.compact
      end

      def copy_entry(definition, copy, options)
        from = copy.from.respond_to?(:call) ? copy.from.call(options) : copy.from
        content = File.binread(template(from || "#{definition.name}/#{copy.path}"))
        entry = { path: copy.path, module: definition.name, role: copy.role }

        case @files.compare(copy.path, content)
        when :missing
          @files.create(copy.path, content, executable: copy.executable)
          entry.merge(action: :created, examples: example_tags(content))
        when :same then nil
        else entry.merge(action: :conflict)
        end
      end

      def migration_entries(definition, migration)
        target_dir = "db/migrate"
        return [] unless @files.glob("#{target_dir}/*_#{migration.name}.up.sql").empty?

        stamp = (@now + @migration_count).strftime("%Y%m%d%H%M%S")
        @migration_count += 1
        %w[up down].map do |direction|
          pattern = File.join(@registry.templates_dir, definition.name.to_s, target_dir,
            "*_#{migration.name}.#{direction}.sql",)
          source = Dir[pattern].first || raise(ArgumentError, "no template migration matches #{pattern}")
          path = "#{target_dir}/#{stamp}_#{migration.name}.#{direction}.sql"
          @files.create(path, File.binread(source))
          { path: path, module: definition.name, role: :wiring, action: :created, examples: [] }
        end
      end

      def gem_entries(definition)
        names = definition.gems.filter_map do |line|
          name = line[/\Agem\s+["']([^"']+)/, 1]
          next if @files.read("Gemfile").match?(/^\s*gem\s+["']#{Regexp.escape(name)}["']/)

          @files.append("Gemfile", "#{line}\n")
          name
        end
        names.empty? ? [] : [appended("Gemfile", definition, names)]
      end

      def env_entries(definition)
        definition.envs.group_by(&:file).filter_map do |file, envs|
          path = Definition::ENV_FILES.fetch(file)
          keys = envs.filter_map do |env|
            next if @files.read(path).match?(/^#?\s*#{Regexp.escape(env.key)}=/)

            value = env.value.respond_to?(:call) ? env.value.call(app_name) : env.value
            @files.append(path, "#{"# " if env.commented}#{env.key}=#{value}\n")
            env.key
          end
          appended(path, definition, keys) unless keys.empty?
        end
      end

      def ignore_entries(definition)
        %w[.gitignore .dockerignore].filter_map do |path|
          lines = definition.ignores.reject { |line| @files.read(path).lines.map(&:chomp).include?(line) }
          lines.each { |line| @files.append(path, "#{line}\n") }
          appended(path, definition, lines) unless lines.empty?
        end
      end

      def appended(path, definition, items)
        { path: path, module: definition.name, action: :appended, items: items }
      end

      # SETUP.md and AGENTS.md: each added module's section, after the
      # others, marked so it's never added twice.
      def section_entries
        { setup: "SETUP.md", agents: "AGENTS.md" }.filter_map do |kind, path|
          names = @plan.filter_map do |definition, _|
            section = definition.sections[kind]
            marker = "<!-- monk:module #{definition.name} -->"
            next if section.nil? || @files.read(path).include?(marker)

            body = File.read(template(section)).gsub("{{app}}", app_name)
            @files.append(path, "\n#{marker}\n#{body}")
            definition.name
          end
          { path: path, action: :appended, items: names, sections: true } unless names.empty?
        end
      end

      # [tag, line number] for each `# monk:example <tag>` in a file.
      def example_tags(content)
        content.each_line.with_index(1).filter_map do |line, number|
          tag = line[/#\s*monk:example\s+(\S+)/, 1]
          [tag, number] if tag
        end
      end

      def result(entries)
        entries += section_entries
        @files.write! unless @dry_run
        conflicts, done = entries.partition { |entry| entry[:action] == :conflict }
        Result.new(
          status: :ok, written: !@dry_run && !done.empty?, dry_run: @dry_run, requested: @requested,
          modules: module_entries, files: done, skipped: conflicts.map { |entry| skipped(entry) },
          env: production_entries, examples: examples(entries), services: services, next_steps: next_steps(entries),
          docs: docs(entries), closing: @plan.map { |definition, _| definition.closing }.compact.last,
          command: @command,
        )
      end

      def module_entries
        added = @plan.map do |definition, options|
          entry = { name: definition.name, action: :added }
          needed_by = @needed_by[definition.name]
          entry[:reason] = "needed by #{needed_by.join(", ")}" unless @requested.include?(definition.name)
          entry[:options] = options unless options.empty?
          entry
        end
        already = (@requested & @installed).map { |name| { name: name, action: :already_installed } }
        needed = @plan.flat_map { |definition, options| definition.dependencies(options) }.uniq
        dependencies_installed = ((needed & @installed) - @requested).map do |name|
          { name: name, action: :already_installed, reason: "needed by #{needers(name).join(", ")}" }
        end
        already + dependencies_installed + added
      end

      def needers(name)
        @plan.filter_map { |definition, options| definition.name if definition.dependencies(options).include?(name) }
      end

      def skipped(entry)
        entry.slice(:path, :module, :role).merge(show: "monk help #{entry[:module]} --file #{entry[:path]}")
      end

      def production_entries
        @plan.flat_map do |definition, _|
          definition.productions.map do |production|
            files = definition.envs.select { |env| env.key == production.key }.map { |env| Definition::ENV_FILES.fetch(env.file) }
            { key: production.key, module: definition.name, files: files, placeholder: production.placeholder,
              required_in: %w[staging production], note: production.note, }
          end
        end
      end

      def examples(entries)
        all = (@installed + @plan.map { |definition, _| definition.name }).map(&:to_s)
        entries.select { |entry| entry[:action] == :created }.flat_map do |entry|
          definition = @registry.fetch(entry[:module])
          entry[:examples].map do |tag, line|
            todo = definition.examples.find { |example| example.tag == tag }&.todo
            todo = todo.call(all) if todo.respond_to?(:call)
            { tag: tag, path: entry[:path], line: line, module: entry[:module], todo: todo }.compact
          end
        end
      end

      def services
        @plan.flat_map { |definition, _| definition.services }.uniq(&:name)
             .map { |service| { name: service.name, check: service.check, setup: service.setup } }
      end

      # Every step, in order: bundle install when gems were added, each
      # module's own steps, bin/setup_db when a migration was, and the tests.
      def next_steps(entries)
        all_services = (@installed.map { |name| @registry.fetch(name) } + @plan.map(&:first))
                       .flat_map(&:services).map(&:name).uniq
        steps = []
        gems_added = entries.any? { |entry| entry[:path] == "Gemfile" && entry[:action] == :appended }
        steps << { run: "bundle install" } if gems_added
        @plan.map(&:first).each { |definition| definition.steps.each { |step| steps << step_entry(step) } }
        migrating = entries.select { |entry| entry[:path].start_with?("db/migrate/") && entry[:action] == :created }
        unless migrating.empty?
          needed = services_of(migrating.map { |entry| entry[:module] }.uniq)
          steps << { run: "bin/setup_db", needs_service: (needed.join(",") unless needed.empty?) }.compact
        end
        steps << { run: "bundle exec rake test",
                   needs_service: (all_services.join(",") unless all_services.empty?), }.compact
        steps.uniq
      end

      # The services these modules need, theirs or their dependencies'.
      def services_of(names)
        seen = []
        queue = names.dup
        until queue.empty?
          name = queue.shift
          next if seen.include?(name)

          seen << name
          options = @plan.find { |definition, _| definition.name == name }&.last || {}
          queue.concat(@registry.fetch(name).dependencies(options))
        end
        seen.flat_map { |name| @registry.fetch(name).services }.map(&:name).uniq
      end

      def step_entry(step)
        key = step.text.match?(%r{\A(bin/|bundle |ruby |curl |open )}) ? :run : :do
        { key => step.text, needs_service: step.needs_service }.compact
      end

      def docs(entries)
        entries.select { |entry| entry[:sections] }.flat_map do |entry|
          entry[:items].map { |name| "#{entry[:path]}##{name}" }
        end
      end

      def conflict_result(conflicts)
        first = conflicts.first
        message = "#{first[:path]} exists and differs, and #{first[:module]} needs it to run."
        message = "#{conflicts.size} files #{first[:module]} needs exist and differ." if conflicts.size > 1
        Result.new(
          status: :conflict, written: false, dry_run: @dry_run, requested: @requested, message: message,
          conflicts: conflicts.map { |entry| skipped(entry) }, command: @command,
        )
      end

      def error_result(status, message, suggestion: nil, choice: nil)
        Result.new(status: status, written: false, dry_run: @dry_run, requested: @requested, message: message,
          suggestion: suggestion, choice: choice, command: @command,)
      end

      def template(path)
        File.join(@registry.templates_dir, path)
      end

      def app_name = File.basename(@dir)
    end

    # The app's files as the run will leave them: read from disk once, then
    # changed in memory, and written only by write!.
    class Files
      def initialize(dir)
        @dir = dir
        @contents = {}
        @changed = {}
        @executable = []
      end

      def read(path)
        @contents.fetch(path) do
          full = File.join(@dir, path)
          @contents[path] = File.exist?(full) ? File.binread(full) : +""
        end
      end

      def compare(path, content)
        return :missing unless exists?(path)

        read(path) == content ? :same : :different
      end

      def exists?(path) = @changed.key?(path) || File.exist?(File.join(@dir, path))

      def glob(pattern)
        on_disk = Dir.glob(pattern, base: @dir)
        on_disk + @changed.keys.select { |path| File.fnmatch?(pattern, path) }
      end

      def create(path, content, executable: false)
        @contents[path] = content.dup
        @changed[path] = true
        @executable << path if executable
      end

      def append(path, text)
        current = read(path)
        current = "#{current}\n" unless current.empty? || current.end_with?("\n")
        @contents[path] = current + text
        @changed[path] = true
      end

      def write!
        @changed.each_key do |path|
          full = File.join(@dir, path)
          FileUtils.mkdir_p(File.dirname(full))
          File.binwrite(full, @contents.fetch(path))
          File.chmod(0o755, full) if @executable.include?(path)
        end
        @changed.clear
      end
    end
  end
end
