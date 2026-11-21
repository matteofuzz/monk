require_relative "test_helper"

class RedirectTest < Minitest::Test
  def app
    Class.new(Monk::Base) do
      get("/go") { redirect(params[:to]) }
      get("/out") { redirect("https://bucket.example/file?sig=1", allow_other_host: true) }
      get("/moved") { redirect("/new", status: 301) }
    end
  end

  def test_paths_and_urls_on_this_host_redirect
    ["/notes", "/notes?page=2#top", "notes/1", "?page=2", "https://app.example/notes",
     "http://app.example/x",].each do |to|
      status, headers, _body = go(to)

      assert_equal [302, to], [status, headers["location"]], to
    end
  end

  def test_a_port_counts_as_part_of_the_host
    assert_equal 302, go("http://localhost:9292/x", host: "localhost:9292").first
    assert_equal 500, go("http://localhost:9293/x", host: "localhost:9292").first
  end

  def test_other_hosts_and_browser_quirks_are_refused
    ["https://evil.example/", "//evil.example/", "/\\evil.example/", "\\\\evil.example",
     "http:/evil.example", "https:evil.example", "https://app.example@evil.example/",
     "javascript:alert(1)", "mailto:a@b.example", "/\t/evil.example", " //evil.example",
     "/x\r\nset-cookie: a=1", "",].each do |to|
      status, headers, _body = go(to)

      assert_equal 500, status, to.inspect
      assert_nil headers["location"], to.inspect
    end
  end

  def test_the_error_is_an_unsafe_redirect_error_an_app_can_handle
    handled = Class.new(Monk::Base) do
      get("/go") { redirect(params[:to]) }
      error(Monk::UnsafeRedirectError) { redirect("/") }
    end
    env = env_for("GET", "/go").merge("QUERY_STRING" => "to=https://evil.example", "HTTP_HOST" => "app.example")

    _status, headers, _body = handled.call(env)

    assert_equal "/", headers["location"]
  end

  def test_allow_other_host_lets_the_app_redirect_anywhere
    status, headers, _body = app.call(env_for("GET", "/out"))

    assert_equal [302, "https://bucket.example/file?sig=1"], [status, headers["location"]]
  end

  def test_the_status_is_kept
    assert_equal 301, app.call(env_for("GET", "/moved")).first
  end

  def test_checked_in_a_real_worker_ractor
    redirecting = Class.new(Monk::Base) { get("/go") { redirect(params[:to]) } }
    boot_quietly(redirecting)

    statuses = Ractor.new(redirecting) do |a|
      %w[/notes https://app.example/x https://evil.example/].map do |to|
        a.call("REQUEST_METHOD" => "GET", "PATH_INFO" => "/go", "QUERY_STRING" => "to=#{to}",
          "HTTP_HOST" => "app.example",).first
      end
    end.value

    assert_equal [302, 302, 500], statuses
  end

  private

  def go(to, host: "app.example")
    env = env_for("GET", "/go").merge("QUERY_STRING" => URI.encode_www_form(to: to), "HTTP_HOST" => host)
    quietly { app.call(env) }
  end
end
