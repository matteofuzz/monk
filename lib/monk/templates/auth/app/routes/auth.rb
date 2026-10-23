# Logging in by email link (monk add auth). Monk::Auth makes and checks the
# tokens and sessions; these routes are the app's own, because they carry
# its decisions: the rate limit, where to go after logging in, JSON or HTML.
#
# monk:example auth-routes -- log in by email link, log out, a page for logged-in users.
# # Before going live: keep the rate limit (without one, anyone can make this
# # app send mail to any address), and list your redirects in config/auth.rb.
# class App
#   get("/login") { @title = "Log in"; render "auth/login" }
#
#   # app/views/auth/login.erb sends {"email": "..."} as JSON.
#   post("/auth/request") do
#     email = params[:email].to_s.strip.downcase
#     halt(422) if email.empty?
#     # One link per address per login_request_interval (config/auth.rb),
#     # counted in the database, so across every bin/server process.
#     halt(429) unless Monk::Auth.allow_login_request?(email)
#
#     # Sent here, in the request. With jobs, replace these two lines with
#     # Monk::Auth::SendLoginLink.enqueue(email): the token is then made and
#     # sent in bin/jobs, and never stored.
#     token = Monk::Auth.request_login(email)
#     Monk::Auth.deliver_link(email: email, link: Monk::Auth.login_link(token), token: token)
#     json(sent: true)
#   end
#
#   # The link in the email: callback_path in config/auth.rb.
#   get("/auth/callback/:token") do
#     session = Monk::Auth.redeem(params[:token]) || halt(401, "This link has expired or was already used.")
#     set_session_cookie(session)
#     redirect(session[:redirect_to] || "/")
#   end
#
#   # From a page: fetch("/auth/logout", { method: "POST", headers: { "x-csrf-token": csrfToken } }),
#   # where csrfToken is the csrf_token cookie's value.
#   post("/auth/logout") do
#     require_csrf!
#     log_out!
#     json(logged_out: true)
#   end
#
#   get("/me") { json(email: require_user!) }
# end
# monk:end
