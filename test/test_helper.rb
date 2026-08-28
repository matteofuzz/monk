$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
ENV["MONK_ENV"] ||= "production"

require "minitest/autorun"
require "stringio"
require "monk"

module EnvHelper
  def env_for(method, path)
    {
      "REQUEST_METHOD" => method,
      "PATH_INFO" => path,
      "rack.input" => StringIO.new(""),
    }
  end
end

Minitest::Test.include(EnvHelper)
