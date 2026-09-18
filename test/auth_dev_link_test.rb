require_relative "test_helper"
require "monk/auth"

class AuthDevLinkTest < Minitest::Test
  # Monk::Log.write needs @path set, which only happens via
  # #freeze_registry! -- normally triggered by Base#freeze! (real app
  # boot) via Monk.freeze_hooks. This test calls Monk::Auth.log_dev_link
  # directly with no app/boot involved, so it has to trigger that itself.
  #
  # with_settings resets Monk::Settings.booted? too -- required here, not
  # just tidy: once *any* other test in this same process has booted a
  # real app, Settings[:monk_env] reads back its frozen snapshot instead
  # of live ENV (settings.rb's #[] "Before Boot .. After Boot" split), so
  # without resetting it first, with_monk_env's ENV override below would
  # be silently ignored depending on run/test order.
  def test_logs_the_link_to_stdout_and_the_dev_log_in_development
    contents = with_log do |dir|
      out, = with_settings do
        with_monk_env("development") do
          Monk::Log.freeze_registry!
          capture_io { Monk::Auth.log_dev_link("http://x/auth/callback/abc") }
        end
      end

      assert_includes out, "[dev] magic link: http://x/auth/callback/abc"
      log = File.read(File.join(dir, "development.log"))
      assert_match(/INFO \[dev\] magic link: http:\/\/x\/auth\/callback\/abc/, log)
    end
  end

  def test_includes_the_optional_subject_in_the_printed_line
    out, = with_log do
      with_settings do
        with_monk_env("development") do
          Monk::Log.freeze_registry!
          capture_io { Monk::Auth.log_dev_link("http://x/auth/callback/abc", subject: "a@b.com") }
        end
      end
    end

    assert_includes out, "[dev] magic link for a@b.com: http://x/auth/callback/abc"
  end

  def test_also_prints_a_scannable_qr_code_when_rqrcode_is_available
    out, = with_log do
      with_settings do
        with_monk_env("development") do
          Monk::Log.freeze_registry!
          capture_io { Monk::Auth.log_dev_link("http://x/auth/callback/abc") }
        end
      end
    end

    # rqrcode is a development dependency of monk itself (monk.gemspec),
    # so it's always available in this test suite -- the QR renders as
    # ANSI-escaped block characters, several lines long.
    assert_operator out.lines.count, :>, 10
    assert_includes out, "\e["
  end

  def test_is_a_no_op_outside_development
    out, = with_log do
      with_settings do
        with_monk_env("test") do
          Monk::Log.freeze_registry!
          capture_io { Monk::Auth.log_dev_link("http://x/auth/callback/abc") }
        end
      end
    end

    assert_equal "", out
  end
end
