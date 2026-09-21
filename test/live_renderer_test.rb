require_relative "test_helper"
require "monk/live"

class LiveRendererTest < Minitest::Test
  ROW = %(<li id="contact-<%= locals[:contact][:id] %>"><%= locals[:contact][:name] %></li>).freeze

  def test_renders_a_partial_to_a_string
    with_frozen_views({ "contacts/_row.erb" => ROW }) do
      html = Monk::Live::Renderer.render("contacts/_row", contact: { id: 42, name: "Ada" })

      assert_equal %(<li id="contact-42">Ada</li>), html
    end
  end

  def test_never_wraps_the_fragment_in_the_default_layout
    templates = { "layouts/app.erb" => "<html><%= yield %></html>", "contacts/_row.erb" => ROW }

    with_frozen_views(templates, layout: "layouts/app") do
      html = Monk::Live::Renderer.render("contacts/_row", contact: { id: 1, name: "x" })

      assert_equal %(<li id="contact-1">x</li>), html
    end
  end

  def test_result_is_a_frozen_shareable_plain_string
    with_frozen_views({ "contacts/_row.erb" => ROW }) do
      html = Monk::Live::Renderer.render("contacts/_row", contact: { id: 1, name: "x" })

      assert_instance_of String, html
      assert_predicate html, :frozen?
      assert Ractor.shareable?(html)
    end
  end

  def test_interpolation_is_html_escaped
    with_frozen_views({ "contacts/_row.erb" => ROW }) do
      html = Monk::Live::Renderer.render("contacts/_row", contact: { id: 1, name: "<script>" })

      assert_equal %(<li id="contact-1">&lt;script&gt;</li>), html
    end
  end

  def test_a_partial_can_render_another_partial
    templates = {
      "contacts/_row.erb" => %(<li><%= render "contacts/_dot", status: locals[:status], layout: false %></li>),
      "contacts/_dot.erb" => %(<i class="<%= locals[:status] %>"></i>),
    }

    with_frozen_views(templates) do
      assert_equal %(<li><i class="away"></i></li>), Monk::Live::Renderer.render("contacts/_row", status: "away")
    end
  end

  def test_an_unknown_partial_raises_template_not_found
    with_frozen_views({ "contacts/_row.erb" => ROW }) do
      error = assert_raises(Monk::TemplateNotFoundError) { Monk::Live::Renderer.render("nope") }

      assert_includes error.message, "nope"
    end
  end

  def test_a_layout_local_is_rejected_rather_than_silently_swallowed
    with_frozen_views({ "contacts/_row.erb" => ROW }) do
      error = assert_raises(ArgumentError) do
        Monk::Live::Renderer.render("contacts/_row", layout: "layouts/app", contact: { id: 1, name: "x" })
      end

      assert_includes error.message, "layout"
    end
  end

  def test_raises_a_clear_error_when_views_were_never_frozen
    with_views("contacts/_row.erb" => ROW) do
      error = assert_raises(Monk::Live::NotFrozenError) do
        Monk::Live::Renderer.render("contacts/_row", contact: { id: 1, name: "x" })
      end

      assert_includes error.message, "Monk.freeze!"
    end
  end

  def test_renders_from_a_non_main_ractor
    with_frozen_views({ "contacts/_row.erb" => ROW }) do
      ractor = Ractor.new do
        Monk::Live::Renderer.render("contacts/_row", contact: { id: 7, name: "Grace" })
      end

      assert_equal %(<li id="contact-7">Grace</li>), ractor.value
    end
  end

  def test_a_hash_row_like_persistence_returns_crosses_into_a_ractor_as_a_local
    with_frozen_views({ "contacts/_row.erb" => ROW }) do
      row = { id: 9, name: "Row", seen_at: Time.at(0), note: nil } # unfrozen, like Pg::Model.to_row
      ractor = Ractor.new(row) { |contact| Monk::Live::Renderer.render("contacts/_row", contact: contact) }

      assert_equal %(<li id="contact-9">Row</li>), ractor.value
    end
  end

  def test_a_non_main_ractor_gets_the_not_frozen_error_not_an_isolation_error
    with_views("contacts/_row.erb" => ROW) do
      ractor = Ractor.new do
        Monk::Live::Renderer.render("contacts/_row", contact: { id: 1, name: "x" })
      rescue Monk::Live::NotFrozenError => e
        e.class
      end

      assert_equal Monk::Live::NotFrozenError, ractor.value
    end
  end
end
