require_relative "../test_helper"

# monk add mail (docs/history/plan-scaffold.md, "mail"): no Postgres needed.
class GeneratorsMailTest < Minitest::Test
  include GeneratorTestHelpers

  def test_writes_the_mail_config_gem_and_env
    with_new_app(:mail) do |dest|
      assert_equal template("mail/config/mail.rb"), generated(dest, "config/mail.rb")
      assert_includes generated(dest, "Gemfile"), %(gem "net-smtp")
      assert_includes generated(dest, ".env"), %(MAIL_FROM="shop <no-reply@localhost>"\n)
      refute_includes generated(dest, ".env"), "MAIL_URL", "unset in development: printed, not sent"
      assert_includes generated(dest, ".env.test"), "MAIL_URL=log://\n"
      assert_includes generated(dest, ".env.example"), "MAIL_URL=smtp://"
    end
  end

  # The mailer file is mail's: auth writes its own (docs/history/plan-scaffold.md
  # decision 10), so the two never write the same file.
  def test_writes_the_app_mailer_with_a_commented_example
    with_new_app(:mail) do |dest|
      assert_includes generated(dest, "app/mailers/app_mailer.rb"), "# monk:example mail-welcome"
      assert File.exist?(File.join(dest, "app/views/mail/welcome.erb"))
    end
  end

  def test_needs_no_other_module_and_lists_what_to_set
    with_new_app do |dest|
      result = add_modules(dest, :mail)

      assert_equal([:mail], result.modules.map { |entry| entry[:name] })
      assert_equal(%w[MAIL_URL MAIL_FROM], result.env.map { |entry| entry[:key] })
    end
  end

  def test_the_apps_own_tests_pass
    with_new_app(:mail) { |dest| assert_generated_tests_pass(dest) }
  end
end
