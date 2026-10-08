require_relative "test_helper"
require "open3"
require "monk/live"
require "monk/websocket/registry"

# <%= monk_head %> in a layout renders the <head> tags of every loaded
# module (docs/adr/0017), so adding a module never edits the layout. Each
# module's helpers add theirs with `def head_tags = super + [...]`.
class HeadTest < Minitest::Test
  module ExtraTag
    def head_tags
      super + [%(<meta name="extra" content="1">)]
    end
  end

  def test_monk_head_is_empty_when_no_module_adds_a_tag
    out, err, status = Open3.capture3(
      RbConfig.ruby, "-I", File.expand_path("../lib", __dir__), "-e",
      'require "monk"; head = Monk::Context.new({}).monk_head; print head.class, " ", head.to_s.inspect',
    )

    assert status.success?, err
    assert_equal %(Monk::Views::Raw ""), out
  end

  def teardown
    Monk::Live.reset!
  end

  # This suite loads monk/live, so Live's tags are in the chain too.
  def test_a_module_adds_its_tags_after_the_ones_before_it
    with_configured_live("ws://localhost:9293") do
      context_class = Class.new(Monk::Context) { include ExtraTag }

      tags = context_class.new({}).head_tags

      assert_equal %(<meta name="extra" content="1">), tags.last
      assert_includes tags.first, "monk-live-url"
    end
  end

  def test_monk_head_joins_the_tags_one_per_line_unescaped
    context_class = Class.new(Monk::Context) do
      def head_tags = [%(<a>), %(<b>)]
    end

    assert_equal "<a>\n<b>", Monk::Views.h(context_class.new({}).monk_head).to_s
  end

  def test_live_adds_its_websocket_url_and_client_script
    with_configured_live(%(ws://localhost:9293/"x)) do
      head = Monk::Context.new({}).monk_head.to_s

      assert_includes head, %(<meta name="monk-live-url" content="ws://localhost:9293/&quot;x">)
      assert_match(%r{<script type="module" src="[^"]*monk_live\.js"></script>}, head)
    end
  end

  # monk/live loaded but config/live.rb never ran (an app without
  # live_ws_url declared): no tags, rather than an UnknownSettingError
  # from every layout.
  def test_live_adds_nothing_until_it_is_configured
    with_settings do
      assert_equal "", Monk::Context.new({}).monk_head.to_s
    end
  end

  private

  # What config/live.rb does: declare live_ws_url, configure Live.
  def with_configured_live(url, &)
    with_settings do
      with_env("LIVE_WS_URL", url) do
        Monk::Settings.configure { optional :live_ws_url, default: "ws://localhost:9293" }
        Monk::Live.configure(registry: Monk::WebSocket::Registry.new)
        yield
      end
    end
  end
end
