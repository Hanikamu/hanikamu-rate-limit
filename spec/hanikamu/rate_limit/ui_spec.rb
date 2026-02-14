# frozen_string_literal: true

require "rack"
require "rack/test"
require "json"
require "rails"
require "hanikamu/rate_limit/ui/engine"
require "hanikamu/rate_limit/ui/config/routes"
require File.expand_path(
  "../../../lib/hanikamu/rate_limit/ui/app/controllers/hanikamu/rate_limit/ui/dashboard_controller",
  __dir__
)

RSpec.describe "Hanikamu::RateLimit::UI" do
  include Rack::Test::Methods

  def app
    routes = ActionDispatch::Routing::RouteSet.new
    routes.draw do
      mount Hanikamu::RateLimit::UI::Engine => "/rate-limits"
    end
    routes
  end

  before do
    Hanikamu::RateLimit.configure do |config|
      config.ui_auth = ->(_controller) { true }
      config.ui_max_sse_connections = 10
    end
    # Reset connection counter between tests
    Hanikamu::RateLimit::UI::DashboardController.sse_connections.value = 0
  end

  it "denies access by default when ui_auth is not configured" do
    Hanikamu::RateLimit.configure do |config|
      config.ui_auth = nil
    end

    get "/rate-limits"

    expect(last_response.status).to eq(403)
    expect(last_response.body).to include("ui_auth is not configured")
  end

  it "denies metrics endpoint when ui_auth is not configured" do
    Hanikamu::RateLimit.configure do |config|
      config.ui_auth = nil
    end

    get "/rate-limits/metrics"

    expect(last_response.status).to eq(403)
  end

  it "denies stream endpoint when ui_auth is not configured" do
    Hanikamu::RateLimit.configure do |config|
      config.ui_auth = nil
    end

    get "/rate-limits/stream"

    expect(last_response.status).to eq(403)
  end

  it "serves the dashboard when auth allows" do
    get "/rate-limits"

    expect(last_response.status).to eq(200)
    expect(last_response.body).to include("Rate Limit Metrics")
  end

  it "serves metrics JSON when auth allows" do
    get "/rate-limits/metrics"

    expect(last_response.status).to eq(200)
    payload = JSON.parse(last_response.body)
    expect(payload).to include("limits")
    expect(payload).to include("generated_at")
  end

  it "rejects requests when auth denies" do
    Hanikamu::RateLimit.configure do |config|
      config.ui_auth = ->(_controller) { false }
    end

    get "/rate-limits"

    expect(last_response.status).to eq(401)
    expect(last_response.body).to include("Unauthorized")
  end

  it "supports zero-arity auth" do
    Hanikamu::RateLimit.configure do |config|
      config.ui_auth = -> { true }
    end

    get "/rate-limits"

    expect(last_response.status).to eq(200)
  end

  it "passes the controller instance to the auth callable" do
    received_controller = nil
    Hanikamu::RateLimit.configure do |config|
      config.ui_auth = lambda { |controller|
        received_controller = controller
        true
      }
    end

    get "/rate-limits"

    expect(last_response.status).to eq(200)
    expect(received_controller).to be_a(Hanikamu::RateLimit::UI::DashboardController)
  end

  it "rejects metrics endpoint when auth denies" do
    Hanikamu::RateLimit.configure do |config|
      config.ui_auth = ->(_controller) { false }
    end

    get "/rate-limits/metrics"

    expect(last_response.status).to eq(401)
  end

  it "rejects stream endpoint when auth denies" do
    Hanikamu::RateLimit.configure do |config|
      config.ui_auth = ->(_controller) { false }
    end

    get "/rate-limits/stream"

    expect(last_response.status).to eq(401)
  end

  it "returns 401 when auth callable raises an error" do
    Hanikamu::RateLimit.configure do |config|
      config.ui_auth = ->(_controller) { raise "auth broken" }
    end

    get "/rate-limits"

    expect(last_response.status).to eq(401)
    expect(last_response.body).to include("Unauthorized")
  end

  it "returns 503 when SSE connection limit is reached" do
    Hanikamu::RateLimit.configure do |config|
      config.ui_max_sse_connections = 2
    end
    Hanikamu::RateLimit::UI::DashboardController.sse_connections.value = 2

    get "/rate-limits/stream"

    expect(last_response.status).to eq(503)
    expect(last_response.body).to include("Too many SSE connections")
  end

  it "allows SSE connections when under the limit" do
    stub_const("Hanikamu::RateLimit::UI::DashboardController::SSE_TIMEOUT", 0.01)
    stub_const("Hanikamu::RateLimit::UI::DashboardController::SSE_INTERVAL", 0.01)

    Hanikamu::RateLimit.configure do |config|
      config.ui_max_sse_connections = 10
    end
    Hanikamu::RateLimit::UI::DashboardController.sse_connections.value = 0

    get "/rate-limits/stream"

    expect(last_response.status).not_to eq(503)
  end

  it "skips SSE limit when ui_max_sse_connections is nil" do
    stub_const("Hanikamu::RateLimit::UI::DashboardController::SSE_TIMEOUT", 0.01)
    stub_const("Hanikamu::RateLimit::UI::DashboardController::SSE_INTERVAL", 0.01)

    Hanikamu::RateLimit.configure do |config|
      config.ui_max_sse_connections = nil
    end
    Hanikamu::RateLimit::UI::DashboardController.sse_connections.value = 999

    get "/rate-limits/stream"

    expect(last_response.status).not_to eq(503)
  end
end
