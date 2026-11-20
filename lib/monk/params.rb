require "uri"

module Monk
  # Parses a query string or an application/x-www-form-urlencoded body
  # into params with symbol keys, with a small nested syntax:
  #
  #   a=1           {a: "1"}
  #   a[b]=1        {a: {b: "1"}}
  #   a[b][c]=1     {a: {b: {c: "1"}}}
  #   a[]=1&a[]=2   {a: ["1", "2"]}
  #
  # Nothing else: no arrays of hashes (a[][b]), which a form is better
  # off splitting or sending as JSON. A repeated plain key keeps the last
  # value. A name the syntax doesn't match is kept whole as a plain key.
  #
  # Our own code, not Rack::Utils.parse_nested_query: that memoizes an
  # unfrozen parser in a module ivar, which a worker Ractor can't read.
  # Everything here is a frozen constant or a local.
  module Params
    # What a browser's form never comes near, and an attacker's body
    # can't go past. Not settings: one less thing to configure.
    MAX_PAIRS = 1_000
    MAX_DEPTH = 8

    NAME = /\A([^\[\]]+)((?:\[[^\[\]]*\])*)\z/
    SEGMENT = /\[([^\[\]]*)\]/

    # Params that can't be read: a key used as both a value and a hash,
    # past a limit, a malformed body. The request is answered `status`.
    class Error < StandardError
      attr_reader :status

      def initialize(message, status: 400)
        super(message)
        @status = status
      end
    end

    module_function

    def parse(string)
      return {} if string.nil? || string.empty?

      # Lenient: a bad %-sequence stays as written, invalid bytes become
      # U+FFFD, so this never raises.
      pairs = URI.decode_www_form(string)
      raise Error, "more than #{MAX_PAIRS} params" if pairs.size > MAX_PAIRS

      pairs.each_with_object({}) { |(name, value), params| assign(params, name, value) unless name.empty? }
    end

    # Walks the name's keys, creating each hash or array on the way: the
    # key after one says which (empty, as in a[], means an array). Every
    # mismatch with what an earlier param created is an Error.
    def assign(params, name, value)
      match = NAME.match(name)
      return params[name.to_sym] = value unless match

      keys = [match[1], *match[2].scan(SEGMENT).flatten]
      raise Error, "#{name}: nested deeper than #{MAX_DEPTH}" if keys.size > MAX_DEPTH

      *path, last = keys
      container = params
      path.each_with_index do |key, i|
        raise Error, "#{name}: arrays of hashes aren't supported" if key.empty?

        type = keys[i + 1].empty? ? Array : Hash
        container = container[key.to_sym] ||= type.new
        raise Error, "#{name}: conflicts with another param" unless container.is_a?(type)
      end

      if last.empty?
        container << value
      elsif container[last.to_sym].is_a?(Hash) || container[last.to_sym].is_a?(Array)
        raise Error, "#{name}: conflicts with another param"
      else
        container[last.to_sym] = value
      end
    end
  end
end
