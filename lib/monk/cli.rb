require "json"
require "fileutils"
require_relative "generators"

module Monk
  # What exe/monk runs (docs/plan-scaffold.md Phase 5): `monk new`,
  # `monk add`, `monk add --list`, `monk help`. Each answers in text, or
  # as one JSON object with --json, and returns the exit code: 0 done,
  # 1 usage error, 2 a missing choice, 3 a conflict on a wiring file
  # (decision 28). It never prompts without a terminal (decision 23).
  class CLI
    Error = Class.new(StandardError) do
      attr_reader :suggestion

      def initialize(message, suggestion: nil)
        @suggestion = suggestion
        super(message)
      end
    end

    # `monk new`'s flags before docs/adr/0017, in the order --with lists
    # them. Each is a usage error now, showing the command to type instead.
    OLD_FLAGS = %w[postgres auth mail jobs redis live].freeze

    USAGE = <<~TEXT.freeze
      Usage:
        monk new NAME [--with a,b] [options]   create an app, with modules
        monk add MODULE... [options]           add modules to the app here
        monk add --list                        the modules, and which are installed
        monk help [MODULE] [--file PATH]       this, a module's details, or Monk's version of one of its files

      Options:
        --transport=postgres|redis   websocket's transport (inferred when only one is installed)
        --no-demo                    live without its demo
        --dry-run                    say what would be written, and write nothing
        --json                       answer as one JSON object
    TEXT

    def initialize(stdin: $stdin, stdout: $stdout, stderr: $stderr, cwd: Dir.pwd, registry: Generator.registry,
                   now: Time.now)
      @stdin = stdin
      @stdout = stdout
      @stderr = stderr
      @cwd = cwd
      @registry = registry
      @now = now
    end

    def run(argv)
      command, *args = argv
      @args = parse(args)
      case command
      when nil, "help", "--help", "-h" then help
      when "new" then new_app
      when "add" then @args[:list] ? list : add
      else raise Error.new("Unknown command: #{command}.", suggestion: "monk help")
      end
    rescue Error => e
      report(Generator::Result.new(status: :usage_error, written: false, message: e.message, suggestion: e.suggestion))
    end

    private

    def parse(args)
      parsed = { positional: [], options: {}, with: [], old: [] }
      args = args.dup
      until args.empty?
        arg = args.shift
        case arg
        when "--json" then parsed[:json] = true
        when "--dry-run" then parsed[:dry_run] = true
        when "--list" then parsed[:list] = true
        when "--no-demo" then parsed[:options][:demo] = "off"
        when /\A--(with|transport|file)(?:=(.*))?\z/
          value = Regexp.last_match(2) || args.shift || raise(Error, "--#{Regexp.last_match(1)} needs a value.")
          key = Regexp.last_match(1).to_sym
          case key
          when :with then parsed[:with].concat(value.split(",").map(&:strip).reject(&:empty?).map(&:to_sym))
          when :transport then parsed[:options][:transport] = value
          else parsed[:file] = value
          end
        when /\A--(#{OLD_FLAGS.join("|")})\z/ then parsed[:old] << Regexp.last_match(1)
        when /\A-/ then raise Error.new("Unknown option: #{arg}.", suggestion: "monk help")
        else parsed[:positional] << arg
        end
      end
      parsed
    end

    def new_app
      name = @args[:positional].first || raise(Error.new("monk new needs a name.", suggestion: "monk new my_app"))
      old_flags!(name)
      dir = File.expand_path(name, @cwd)
      raise Error.new("#{name} already exists.", suggestion: "cd #{name} && monk add <module>") if File.exist?(dir)

      FileUtils.mkdir_p(dir) unless @args[:dry_run]
      command = "monk new #{name}#{" --with #{@args[:with].join(",")}" unless @args[:with].empty?}"
      result = run_generators(dir, [:base, *@args[:with]], command)
      FileUtils.rm_rf(dir) if !result.ok? && !@args[:dry_run]
      report(result, app: name)
    end

    def add
      modules = @args[:positional].map(&:to_sym)
      raise Error.new("monk add needs a module.", suggestion: "monk add --list") if modules.empty?
      unless monk_app?
        raise Error.new("This isn't a Monk app (no config/load.rb here).",
          suggestion: "monk new my_app, or cd into your app",)
      end

      report(run_generators(@cwd, modules, "monk add #{modules.join(" ")}"))
    end

    # A choice the result says is missing is asked for, in a terminal only,
    # then the run starts over with it.
    def run_generators(dir, modules, command)
      options = @args[:options].dup
      loop do
        result = @registry.add(dir, modules, options: options, dry_run: @args[:dry_run], now: @now, command: command)
        return result unless result.status == :missing_choice && interactive?

        value = ask(result)
        return result unless value

        options[result.choice[:option].to_sym] = value
      end
    end

    def interactive?
      !@args[:json] && @stdin.respond_to?(:tty?) && @stdin.tty?
    end

    def ask(result)
      choice = result.choice
      @stdout.puts result.message, ""
      width = choice[:values].map(&:size).max
      choice[:values].each_with_index do |value, index|
        @stdout.puts "  #{index + 1}) #{value.ljust(width)}   #{choice[:describe]&.fetch(value, nil)}".rstrip
      end
      @stdout.print "\n#{choice[:option].capitalize} [#{(1..choice[:values].size).to_a.join("/")}]: "
      answer = @stdin.gets&.strip.to_s
      number = answer.match?(/\A\d+\z/) ? answer.to_i : 0
      value = number.between?(1, choice[:values].size) ? choice[:values][number - 1] : nil
      value ||= answer if choice[:values].include?(answer)
      @stdout.puts "# Using --#{choice[:option]}=#{value} skips this question." if value
      value
    end

    def old_flags!(name)
      return if @args[:old].empty?

      old = @args[:old]
      transport = (%w[redis postgres] & old).first if old.include?("live")
      with = (OLD_FLAGS & old) - [transport]
      new_form = "monk new #{name} --with #{with.join(",")}#{" --transport=#{transport}" if transport}"
      raise Error.new("monk new no longer takes module flags. The same command is now:", suggestion: new_form)
    end

    def monk_app? = File.exist?(File.join(@cwd, "config/load.rb"))

    def list
      installed = monk_app? ? @registry.definitions.select { |d| File.exist?(File.join(@cwd, d.installed_if)) } : []
      rows = @registry.definitions.reject { |definition| definition.name == :base }.map do |definition|
        list_row(definition, installed.include?(definition))
      end
      if @args[:json]
        @stdout.puts JSON.pretty_generate(modules: rows)
      else
        @stdout.puts "Modules#{" (✓ installed)" if monk_app?}", ""
        width = rows.map { |row| row[:name].size }.max
        rows.each do |row|
          needs = row[:needs].empty? ? row[:needs_one_of] : row[:needs]
          needs_text = "  (needs #{needs.join(row[:needs].empty? ? " or " : ", ")})" unless needs.empty?
          @stdout.puts "  #{row[:installed] ? "✓" : " "} #{row[:name].ljust(width)}   #{row[:summary]}#{needs_text}"
        end
        @stdout.puts "", "Add one: monk add <module>      Details: monk help <module>"
      end
      0
    end

    def list_row(definition, installed)
      dependency_options = definition.options.select { |option| definition.dependency_options.include?(option.name) }
      {
        name: definition.name.to_s, summary: definition.summary, installed: installed,
        needs: definition.dependencies.map(&:to_s), needs_one_of: dependency_options.flat_map(&:values),
        options: definition.options.to_h { |option| [option.name, option.values] },
      }
    end

    def help
      name = @args[:positional].first
      return general_help unless name

      definition = @registry.names.include?(name.to_sym) ? @registry.fetch(name) : nil
      raise Error.new("Unknown module: #{name}.", suggestion: "monk add --list") unless definition
      return file_help(definition) if @args[:file]

      module_help(definition)
    end

    def general_help
      @stdout.puts USAGE, "Modules:"
      @registry.definitions.reject { |definition| definition.name == :base }.each do |definition|
        @stdout.puts "  #{definition.name.to_s.ljust(10)} #{definition.summary}"
      end
      0
    end

    def module_help(definition)
      @stdout.puts "#{definition.name}: #{definition.summary}"
      @stdout.puts "Needs: #{definition.dependencies.join(", ")}" unless definition.dependencies.empty?
      definition.options.each do |option|
        default = " (default #{option.default})" if option.default
        @stdout.puts "Option --#{option.name}: #{option.values.join(", ")}#{default}"
      end
      @stdout.puts "", "Writes:"
      definition.copies.each { |copy| @stdout.puts "  #{copy.path.ljust(32)} #{copy.role}" }
      definition.migrations.each do |migration|
        @stdout.puts "  db/migrate/<timestamp>_#{migration.name}.{up,down}.sql  wiring"
      end
      @stdout.puts "", "Monk's version of one of these: monk help #{definition.name} --file PATH"
      0
    end

    # Monk's version of one of a module's files, for a file the app already
    # had (a conflict, docs/plan-scaffold.md decision 26).
    def file_help(definition)
      path = @args[:file]
      source = migration_template(definition, path) || copy_template(definition, path)
      unless source
        raise Error.new("#{definition.name} doesn't write #{path}.", suggestion: "monk help #{definition.name}")
      end

      @stdout.print File.read(source)
      0
    end

    def migration_template(definition, path)
      migration = definition.migrations.find { |m| path.match?(/_#{Regexp.escape(m.name)}\.(up|down)\.sql\z/) }
      return unless migration

      pattern = "db/migrate/*_#{migration.name}.#{path[/\.(up|down)\.sql\z/, 1]}.sql"
      Dir[File.join(@registry.templates_dir, definition.name.to_s, pattern)].first
    end

    def copy_template(definition, path)
      copy = definition.copies.find { |candidate| candidate.path == path }
      File.join(@registry.templates_dir, template_for_copy(definition, copy)) if copy
    end

    def template_for_copy(definition, copy)
      return "#{definition.name}/#{copy.path}" unless copy.from
      return copy.from unless copy.from.respond_to?(:call)

      options = definition.options.to_h { |option| [option.name, @args[:options][option.name] || option.default] }
      missing = definition.options.find { |option| options[option.name].nil? }
      if missing
        raise Error.new("#{copy.path} depends on --#{missing.name}.",
          suggestion: "monk help #{definition.name} --file #{copy.path} --#{missing.name}=#{missing.values.first}",)
      end
      copy.from.call(options)
    end

    def report(result, app: nil)
      if @args&.fetch(:json, false)
        hash = result.to_h
        hash["app"] = app if app
        @stdout.puts JSON.pretty_generate(hash)
      elsif result.ok?
        @stdout.print app ? result.new_text(app) : result.to_text
      else
        @stderr.print result.to_text
      end
      result.exit_code
    end
  end
end
