require_relative "test_helper"
require "json"
require "timeout"
require "monk/websocket"
require "monk/live"

class LivePublisherTest < Minitest::Test
  ROW = %(<li id="contact-<%= locals[:contact][:id] %>"><%= locals[:contact][:name] %></li>).freeze
  TEMPLATES = { "contacts/_row.erb" => ROW }.freeze

  def setup
    @registry = Monk::WebSocket::Registry.new
    @publisher = Monk::Live::Publisher.new(@registry)
  end

  def teardown
    Monk::Live.reset!
  end

  def test_patch_delivers_a_rendered_patch_envelope_to_a_topics_subscribers
    with_frozen_views(TEMPLATES) do
      port = subscribe(:"contacts:7")

      @publisher.patch("contacts:7", to: "#contact-42", partial: "contacts/_row", contact: { id: 42, name: "Ada" })

      assert_equal(
        { "op" => "patch", "target" => "#contact-42", "mode" => "morph", "html" => %(<li id="contact-42">Ada</li>) },
        JSON.parse(receive(port)),
      )
    end
  end

  def test_one_render_is_shared_by_reference_across_all_subscribers
    with_frozen_views(TEMPLATES) do
      ports = 3.times.map { subscribe(:t) }

      @publisher.patch("t", to: "#c", partial: "contacts/_row", contact: { id: 1, name: "x" })
      messages = ports.map { |port| receive(port) }

      assert_predicate messages.first, :frozen?
      assert messages.all? { |message| message.equal?(messages.first) }, "each port got its own copy"
    end
  end

  def test_other_topics_do_not_receive_it
    with_frozen_views(TEMPLATES) do
      other = subscribe(:other)
      mine = subscribe(:mine)

      @publisher.patch("mine", to: "#c", partial: "contacts/_row", contact: { id: 1, name: "x" })
      @publisher.remove("other", to: "#marker")

      assert JSON.parse(receive(mine))["html"]
      assert_equal "remove", JSON.parse(receive(other))["mode"] # first thing `other` got is the marker
    end
  end

  def test_append_prepend_and_replace_set_the_mode
    with_frozen_views(TEMPLATES) do
      port = subscribe(:t)
      locals = { contact: { id: 1, name: "x" } }

      @publisher.append("t", to: "#list", partial: "contacts/_row", **locals)
      @publisher.prepend("t", to: "#list", partial: "contacts/_row", **locals)
      @publisher.patch("t", to: "#list", partial: "contacts/_row", mode: :replace, **locals)

      assert_equal(%w[append prepend replace], 3.times.map { JSON.parse(receive(port))["mode"] })
    end
  end

  def test_remove_needs_no_partial_and_no_render
    port = subscribe(:t) # views deliberately never frozen: remove must not render

    @publisher.remove("t", to: "#contact-9")

    assert_equal({ "op" => "patch", "target" => "#contact-9", "mode" => "remove" }, JSON.parse(receive(port)))
  end

  def test_a_batch_is_one_envelope_with_every_op_rendered_in_order
    with_frozen_views(TEMPLATES) do
      port = subscribe(:t)

      @publisher.batch("t") do |b|
        b.patch(to: "#contact-1", partial: "contacts/_row", contact: { id: 1, name: "one" })
        b.remove(to: "#contact-2")
        b.append(to: "#list", partial: "contacts/_row", contact: { id: 3, name: "three" })
      end
      @publisher.remove("t", to: "#sentinel")

      batch = JSON.parse(receive(port))
      assert_equal "batch", batch["op"]
      assert_equal(%w[morph remove append], batch["ops"].map { |op| op["mode"] })
      assert_equal %(<li id="contact-3">three</li>), batch["ops"].last["html"]
      assert_equal "#sentinel", JSON.parse(receive(port))["target"], "batch was split into several frames"
    end
  end

  def test_an_empty_batch_broadcasts_nothing
    port = subscribe(:t)

    @publisher.batch("t") { |_b| nil }
    @publisher.remove("t", to: "#sentinel")

    assert_equal "#sentinel", JSON.parse(receive(port))["target"]
  end

  def test_an_unknown_mode_is_rejected_before_anything_is_rendered_or_sent
    port = subscribe(:t)

    assert_raises(ArgumentError) { @publisher.patch("t", to: "#a", partial: "nope", mode: :explode) }
    @publisher.remove("t", to: "#sentinel")

    assert_equal "#sentinel", JSON.parse(receive(port))["target"]
  end

  def test_a_render_failure_broadcasts_nothing
    with_frozen_views(TEMPLATES) do
      port = subscribe(:t)

      assert_raises(Monk::TemplateNotFoundError) { @publisher.patch("t", to: "#a", partial: "nope") }
      @publisher.remove("t", to: "#sentinel")

      assert_equal "#sentinel", JSON.parse(receive(port))["target"]
    end
  end

  def test_unfrozen_views_raise_the_not_frozen_error
    with_views(TEMPLATES) do
      assert_raises(Monk::Live::NotFrozenError) do
        @publisher.patch("t", to: "#a", partial: "contacts/_row", contact: { id: 1, name: "x" })
      end
    end
  end

  def test_a_closed_port_is_dropped_and_others_still_receive
    with_frozen_views(TEMPLATES) do
      dead = subscribe(:t)
      live = subscribe(:t)
      dead.close

      @publisher.patch("t", to: "#a", partial: "contacts/_row", contact: { id: 1, name: "x" })

      assert JSON.parse(receive(live))["html"]
      assert_equal 1, @registry.count(:t)
    end
  end

  def test_module_level_calls_need_a_configured_publisher
    assert_raises(Monk::Live::NotConfiguredError) { Monk::Live.remove("t", to: "#a") }
  end

  def test_module_level_calls_delegate_to_the_configured_publisher
    port = subscribe(:t)
    Monk::Live.configure(registry: @registry)

    Monk::Live.remove("t", to: "#a")

    assert_equal "remove", JSON.parse(receive(port))["mode"]
  end

  def test_configure_rejects_a_registry_that_is_not_ractor_shareable
    error = assert_raises(ArgumentError) { Monk::Live.configure(registry: Object.new.tap { |o| o.instance_variable_set(:@x, +"") }) }

    assert_includes error.message, "shareable"
  end

  def test_publishes_from_a_non_main_ractor
    with_frozen_views(TEMPLATES) do
      port = subscribe(:"contacts:7")
      Monk::Live.configure(registry: @registry)

      Ractor.new do
        Monk::Live.patch("contacts:7", to: "#contact-5", partial: "contacts/_row", contact: { id: 5, name: "Grace" })
      end.value

      assert_equal %(<li id="contact-5">Grace</li>), JSON.parse(receive(port))["html"]
    end
  end

  private

  def subscribe(topic)
    port = Ractor::Port.new
    @registry.register(topic.to_sym, port)
    port
  end

  def receive(port)
    Timeout.timeout(3) { port.receive }
  end
end
