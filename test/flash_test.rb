require_relative "test_helper"

class FlashTest < Minitest::Test
  def app
    Class.new(Monk::Base) do
      post("/notes") { redirect "/notes", flash: params[:message] }
      get("/notes") { "#{flash.inspect} #{flash.inspect}" }
      get("/quiet") { "no flash read" }
    end
  end

  def test_a_redirect_leaves_a_message_the_next_page_reads_once
    cookie = flash_cookie_after_post("Saved.")
    assert_match(%r{\Aflash=Saved\.; Path=/; SameSite=Lax; Max-Age=60; Secure; HttpOnly\z}, cookie)

    _status, headers, body = app.call(with_cookie(env_for("GET", "/notes"), cookie))

    assert_equal %("Saved." "Saved."), body.join
    assert_equal ["flash=; Path=/; SameSite=Lax; Max-Age=0; Secure; HttpOnly"], headers["set-cookie"]
  end

  def test_any_text_survives_the_cookie
    message = "Salvato: è; a=b, \"ok\" 100%"
    cookie = flash_cookie_after_post(message)

    assert_equal "#{message.inspect} #{message.inspect}",
      app.call(with_cookie(env_for("GET", "/notes"), cookie))[2].join
  end

  def test_no_message_is_nil_and_sets_no_cookie
    _status, headers, body = app.call(env_for("GET", "/notes"))

    assert_equal "nil nil", body.join
    assert_nil headers["set-cookie"]
  end

  def test_a_page_that_doesnt_read_it_leaves_it_for_the_next
    cookie = flash_cookie_after_post("Saved.")

    assert_nil app.call(with_cookie(env_for("GET", "/quiet"), cookie))[1]["set-cookie"]
  end

  def test_a_cookie_with_bad_encoding_is_nil_and_cleared
    _status, headers, body = app.call(with_cookie(env_for("GET", "/notes"), "flash=%zz"))

    assert_equal "nil nil", body.join
    assert_match(/\Aflash=; .*Max-Age=0/, headers["set-cookie"].first)
  end

  def test_not_secure_in_development
    with_monk_env("development") do
      refute_includes quietly { flash_cookie_after_post("Saved.") }, "Secure"
    end
  end

  def test_round_trip_in_a_real_worker_ractor
    flashing = app
    boot_quietly(flashing)

    result = Ractor.new(flashing) do |a|
      form = { "REQUEST_METHOD" => "POST", "PATH_INFO" => "/notes",
               "CONTENT_TYPE" => "application/x-www-form-urlencoded", "rack.input" => StringIO.new("message=Saved."), }
      cookie = a.call(form)[1]["set-cookie"].first.split(";").first
      a.call("REQUEST_METHOD" => "GET", "PATH_INFO" => "/notes", "HTTP_COOKIE" => cookie)[2].join
    end.value

    assert_equal %("Saved." "Saved."), result
  end

  private

  def flash_cookie_after_post(message)
    env = env_for("POST", "/notes").merge("CONTENT_TYPE" => "application/x-www-form-urlencoded",
      "rack.input" => StringIO.new(URI.encode_www_form(message: message)),)
    status, headers, _body = app.call(env)
    assert_equal 302, status
    headers["set-cookie"].first
  end

  def with_cookie(env, set_cookie)
    env.merge("HTTP_COOKIE" => "other=1; #{set_cookie.split(";").first}")
  end
end
