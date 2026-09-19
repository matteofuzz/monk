require_relative "test_helper"
require "monk/live"

class LiveHelpersTest < Minitest::Test
  def test_live_topic_renders_the_attribute_the_client_looks_for
    with_frozen_views({ "index.erb" => %(<ul <%= live_topic "contacts:7" %>></ul>) }) do
      assert_equal %(<ul data-live-topic="contacts:7"></ul>), Monk::Context.new({}).render("index", layout: false)
    end
  end

  def test_several_topics_are_space_separated_and_symbols_are_accepted
    assert_equal %(data-live-topic="contacts:7 chat:3"), Monk::Context.new({}).live_topic("contacts:7", :"chat:3")
  end

  def test_the_result_is_raw_so_a_template_does_not_escape_it_again
    assert_instance_of Monk::Views::Raw, Monk::Context.new({}).live_topic("a:1")
  end

  def test_a_topic_the_server_would_refuse_is_rejected_at_render_time
    ["", "a b", "contacts:*", "a\"b", "caffè", "x" * 201].each do |topic|
      assert_raises(ArgumentError, topic.inspect) { Monk::Context.new({}).live_topic(topic) }
    end
  end

  def test_at_least_one_topic_is_required
    assert_raises(ArgumentError) { Monk::Context.new({}).live_topic }
  end

  def test_works_from_a_non_main_ractor
    with_frozen_views({ "index.erb" => %(<ul <%= live_topic "a:1" %>></ul>) }) do
      html = Ractor.new { Monk::Context.new({}).render("index", layout: false) }.value

      assert_equal %(<ul data-live-topic="a:1"></ul>), html
    end
  end

  def test_client_dir_holds_the_files_the_runtime_imports
    files = Dir.children(Monk::Live.client_dir)

    assert_equal %w[idiomorph.js monk_live.js protocol.js], files.grep(/\.js\z/).sort
  end
end
