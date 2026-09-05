require_relative "test_helper"

class ResourcesTest < Minitest::Test
  # Plain `def`s, not define_method: a define_method-backed method is a
  # Proc under the hood, and calling one from a Ractor other than the one
  # that defined it raises "defined with an un-shareable Proc in a
  # different Ractor" regardless of the class itself being shareable --
  # the real-worker test below needs a controller that doesn't hit that.
  def build_controller
    Class.new do
      def initialize(context)
        @context = context
      end

      def index = "index:#{@context.params[:id]}"
      def new = "new:#{@context.params[:id]}"
      def create = "create:#{@context.params[:id]}"
      def show = "show:#{@context.params[:id]}"
      def edit = "edit:#{@context.params[:id]}"
      def update = "update:#{@context.params[:id]}"
      def destroy = "destroy:#{@context.params[:id]}"
    end
  end

  def test_rest_with_no_actions_registers_all_seven_default_routes
    controller = build_controller
    app = Class.new(Monk::Base) { resources("widgets", controller) }

    { %w[GET /widgets] => "index:", %w[GET /widgets/new] => "new:",
      %w[POST /widgets] => "create:", %w[GET /widgets/1] => "show:1",
      %w[GET /widgets/1/edit] => "edit:1", %w[PATCH /widgets/1] => "update:1",
      %w[PUT /widgets/1] => "update:1", %w[DELETE /widgets/1] => "destroy:1" }.each do |(verb, path), expected|
      _status, _headers, body = app.call(env_for(verb, path))
      assert_equal expected, body.join
    end
  end

  def test_rest_with_explicit_actions_only_registers_those_routes
    controller = build_controller
    app = Class.new(Monk::Base) { resources("widgets", controller, :index, :create) }

    status, _headers, _body = app.call(env_for("GET", "/widgets"))
    assert_equal 200, status

    status, _headers, _body = app.call(env_for("POST", "/widgets"))
    assert_equal 200, status

    status, _headers, _body = app.call(env_for("GET", "/widgets/1"))
    assert_equal 404, status, "show wasn't requested, so it shouldn't be routed"
  end

  def test_rest_leaves_other_routes_registered_the_ordinary_way_untouched
    controller = build_controller
    app = Class.new(Monk::Base) do
      get("/hello") { "hi" }
      resources("widgets", controller, :index)
    end

    _status, _headers, body = app.call(env_for("GET", "/hello"))
    assert_equal "hi", body.join

    _status, _headers, body = app.call(env_for("GET", "/widgets"))
    assert_equal "index:", body.join
  end

  def test_rest_with_an_unknown_action_raises_immediately
    controller = build_controller

    error = assert_raises(ArgumentError) do
      Class.new(Monk::Base) { resources("widgets", controller, :nope) }
    end

    assert_match(/unknown REST action :nope/, error.message)
  end

  def test_rest_strips_a_leading_slash_from_the_resource
    controller = build_controller
    app = Class.new(Monk::Base) { resources("/widgets", controller, :index) }

    status, _headers, _body = app.call(env_for("GET", "/widgets"))
    assert_equal 200, status
  end

  def test_rest_routes_survive_freeze_and_dispatch_correctly_from_real_worker_ractors
    controller = build_controller
    app = Class.new(Monk::Base) { resources("widgets", controller, :index, :show) }
    Monk.boot(app)

    assert Ractor.shareable?(app.routes)

    results = (1..5).map do |i|
      Ractor.new(app, i) do |a, id|
        status, _headers, body = a.call("REQUEST_METHOD" => "GET", "PATH_INFO" => "/widgets/#{id}")
        [status, body.join]
      end
    end.map(&:value)

    results.each_with_index do |(status, body), index|
      assert_equal 200, status
      assert_equal "show:#{index + 1}", body
    end
  end
end
