require_relative "test_helper"
require "monk/mail"

class MailRenderTest < Minitest::Test
  LINK = %(<p><a href="<%= locals[:link] %>">Log in</a></p>).freeze

  def test_renders_a_template_with_its_locals
    with_frozen_views({ "mail/magic_link.erb" => LINK }) do
      html = Monk::Mail.render("mail/magic_link", link: "https://app.test/auth/callback/abc")

      assert_equal %(<p><a href="https://app.test/auth/callback/abc">Log in</a></p>), html
    end
  end

  # A page layout (<html> with the app's CSS and scripts) is never what an
  # email wants, so the app's default layout is skipped unless asked for.
  def test_skips_the_default_page_layout
    templates = { "layouts/app.erb" => "<html><%= yield %></html>", "mail/magic_link.erb" => LINK }

    with_frozen_views(templates, layout: "layouts/app") do
      html = Monk::Mail.render("mail/magic_link", link: "x")

      refute_includes html, "<html>"
    end
  end

  def test_an_explicit_mail_layout_wraps_the_template
    templates = { "mail/layout.erb" => "<table><%= yield %></table>", "mail/magic_link.erb" => LINK }

    with_frozen_views(templates) do
      html = Monk::Mail.render("mail/magic_link", layout: "mail/layout", link: "x")

      assert_equal %(<table><p><a href="x">Log in</a></p></table>), html
    end
  end

  def test_interpolation_is_html_escaped
    with_frozen_views({ "mail/magic_link.erb" => LINK }) do
      html = Monk::Mail.render("mail/magic_link", link: %("><script>))

      assert_includes html, "&quot;&gt;&lt;script&gt;"
    end
  end

  def test_result_is_a_frozen_plain_string
    with_frozen_views({ "mail/magic_link.erb" => LINK }) do
      html = Monk::Mail.render("mail/magic_link", link: "x")

      assert_instance_of String, html
      assert_predicate html, :frozen?
    end
  end

  def test_renders_from_a_non_main_ractor
    with_frozen_views({ "mail/magic_link.erb" => LINK }) do
      html = Ractor.new { Monk::Mail.render("mail/magic_link", link: "https://app.test/x") }.value

      assert_includes html, "https://app.test/x"
    end
  end

  def test_raises_a_clear_error_before_views_are_frozen
    with_views({ "mail/magic_link.erb" => LINK }) do
      error = assert_raises(Monk::Mail::ViewsNotFrozenError) { Monk::Mail.render("mail/magic_link", link: "x") }

      assert_match(/Monk.boot|Monk.freeze!/, error.message)
    end
  end

  def test_an_unknown_template_raises_template_not_found
    with_frozen_views({ "mail/magic_link.erb" => LINK }) do
      assert_raises(Monk::TemplateNotFoundError) { Monk::Mail.render("mail/nope") }
    end
  end
end
