module Monk
  module Generator
    # One module's generator, as `Monk::Generator.define(:jobs) { ... }`
    # declares it. Only declarations: Run decides what they mean for a given
    # app, and writes nothing until it has checked every file.
    class Definition
      Copy = Data.define(:path, :from, :role, :executable)
      Migration = Data.define(:name)
      Env = Data.define(:file, :key, :value, :commented)
      Option = Data.define(:name, :values, :infer_from, :describe)
      Service = Data.define(:name, :check, :setup)
      Step = Data.define(:text, :needs_service)
      Example = Data.define(:tag, :todo)
      Production = Data.define(:key, :note, :placeholder)

      # What a role means when the file already exists with other content:
      # a wiring file stops the whole command, anything else is skipped
      # (docs/plan-scaffold.md decision 26).
      ROLES = %i[wiring example test view demo].freeze

      # Which .env file each env group appends to.
      ENV_FILES = { development: ".env", test: ".env.test", example: ".env.example" }.freeze

      attr_reader :name, :copies, :migrations, :gems, :envs, :ignores, :options, :services, :steps,
        :examples, :productions, :sections

      def initialize(name)
        @name = name.to_sym
        @summary = ""
        @dependencies = []
        @option_dependencies = []
        @installed_if = "config/#{name}.rb"
        @copies = []
        @migrations = []
        @gems = []
        @envs = []
        @ignores = []
        @options = []
        @services = []
        @steps = []
        @examples = []
        @productions = []
        @sections = {}
        @closing = nil
      end

      def summary(text = nil)
        return @summary if text.nil?

        @summary = text
      end

      # Modules this one needs, added first when they're missing.
      def depends_on(*names)
        @dependencies.concat(names.map(&:to_sym))
      end

      # A choice the user makes (websocket's transport). It's inferred when
      # exactly one of `infer_from` is installed or being added, and the
      # chosen value is a dependency when `dependency: true`.
      def option(name, values:, infer_from: values, dependency: false, describe: {})
        @options << Option.new(name: name.to_sym, values: values.map(&:to_s), infer_from: infer_from.map(&:to_s),
          describe: describe.transform_keys(&:to_s),)
        @option_dependencies << name.to_sym if dependency
      end

      # The file whose existence means this module is installed.
      def installed_if(path = nil)
        return @installed_if if path.nil?

        @installed_if = path
      end

      # A file copied verbatim from templates/<module>/<path>, or from
      # `from:`, a template path or a block taking the options.
      def copy(*paths, role:, from: nil, executable: false)
        raise ArgumentError, "unknown role #{role.inspect}, one of #{ROLES.inspect}" unless ROLES.include?(role)
        raise ArgumentError, "from: needs a single path" if from && paths.size > 1

        paths.each { |path| @copies << Copy.new(path: path, from: from, role: role, executable: executable) }
      end

      # db/migrate/<timestamp>_<name>.{up,down}.sql, from the template
      # migration named *_<name>.{up,down}.sql.
      def migration(name)
        @migrations << Migration.new(name: name)
      end

      # A line appended to the Gemfile unless that gem is already there.
      def gem(line)
        @gems << line
      end

      # A KEY=value line appended to one of the .env files unless KEY is
      # already there (the app's own value wins). The value may be a block
      # taking the app's name.
      def env(file, values, commented: false)
        raise ArgumentError, "unknown env file #{file.inspect}" unless ENV_FILES.key?(file)

        values.each { |key, value| @envs << Env.new(file: file, key: key.to_s, value: value, commented: commented) }
      end

      # A line appended to .gitignore and .dockerignore unless it's there.
      def ignore(line)
        @ignores << line
      end

      def service(name, check:, setup:)
        @services << Service.new(name: name.to_s, check: check, setup: setup)
      end

      # This module's section of SETUP.md or AGENTS.md: a template path.
      def setup_section(path) = @sections[:setup] = path
      def agents_section(path) = @sections[:agents] = path

      def set_before_production(key, note, placeholder: false)
        @productions << Production.new(key: key, note: note, placeholder: placeholder)
      end

      def next_step(text, needs_service: nil)
        @steps << Step.new(text: text, needs_service: needs_service&.to_s)
      end

      # What to do with an example block (`# monk:example <tag>`). `todo`
      # may be a block taking the names of the installed modules.
      def example(tag, todo:)
        @examples << Example.new(tag: tag, todo: todo)
      end

      # The one thing that matters most after adding this module.
      def closing(text = nil)
        return @closing if text.nil?

        @closing = text
      end

      def dependencies(options = {})
        @dependencies + @option_dependencies.filter_map { |option| options[option]&.to_sym }
      end
    end
  end
end
