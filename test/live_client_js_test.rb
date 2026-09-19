require_relative "test_helper"
require "open3"

# The client's pure logic (lib/monk/live/client/protocol.js) is tested with
# Node's built-in runner, no npm involved; this runs it as part of `rake
# test`. Skips without a Node new enough to detect ES modules by syntax.
class LiveClientJsTest < Minitest::Test
  def test_protocol_js_passes_its_node_tests
    skip "node >= 22.7 not available" unless node_supports_esm_detection?

    output, status = Open3.capture2e("node", "--test", "test/js/*.test.js", chdir: File.expand_path("..", __dir__))

    assert status.success?, "node --test failed:\n#{output}"
  end

  private

  def node_supports_esm_detection?
    version, status = Open3.capture2("node", "--version")
    return false unless status.success?

    major, minor = version.delete_prefix("v").split(".").map(&:to_i)
    major > 22 || (major == 22 && minor >= 7)
  rescue Errno::ENOENT
    false
  end
end
