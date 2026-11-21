require_relative "test_helper"

class SecurityHeadersTest < Minitest::Test
  EXPECTED = {
    "x-content-type-options" => "nosniff",
    "content-security-policy" => "frame-ancestors 'none'",
    "referrer-policy" => "strict-origin-when-cross-origin",
  }.freeze

  def app
    Class.new(Monk::Base) do
      get("/x") { "ok" }
      get("/framed") do
        headers["content-security-policy"] = "frame-ancestors https://partner.example"
        "ok"
      end
      post("/x") { "ok" }
    end
  end

  def test_every_response_carries_them
    [env_for("GET", "/x"), env_for("GET", "/missing"),
     env_for("POST", "/x").merge("HTTP_SEC_FETCH_SITE" => "cross-site"),].each do |env|
      _status, headers, _body = app.call(env)

      assert_equal EXPECTED, headers.slice(*EXPECTED.keys), env["PATH_INFO"]
    end
  end

  def test_a_route_replaces_one_by_setting_it
    _status, headers, _body = app.call(env_for("GET", "/framed"))

    assert_equal "frame-ancestors https://partner.example", headers["content-security-policy"]
    assert_equal "nosniff", headers["x-content-type-options"]
  end

  def test_static_files_carry_them_too
    with_assets("css/app.css" => "body {}") do
      static = Class.new(Monk::Base)
      static.assets(Monk::Assets.root)
      boot_quietly(static)
      status, headers, body = static.call(env_for("GET", "/css/app.css"))

      assert_equal [200, "body {}"], [status, body.join]
      assert_equal "nosniff", headers["x-content-type-options"]
    end
  end
end
