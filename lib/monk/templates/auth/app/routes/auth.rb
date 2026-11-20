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
#   # The form in app/views/auth/login.erb; a failed submit renders it
#   # again with the error and its status.
#   post("/auth/request") do
#     @title = "Log in"
#     email = params[:email].to_s.strip.downcase
#     if email.empty?
#       @error = "Enter your email."
#       halt(422, render("auth/login"))
#     end
#     # One link per address per login_request_interval (config/auth.rb),
#     # counted in the database, so across every bin/server process.
#     unless Monk::Auth.allow_login_request?(email)
#       @error = "A link was just sent to this address: check your email, or try again in a minute."
#       halt(429, render("auth/login"))
#     end
#
#     # Sent here, in the request. With jobs, replace these two lines with
#     # Monk::Auth::SendLoginLink.enqueue(email): the token is then made and
#     # sent in bin/jobs, and never stored.
#     token = Monk::Auth.request_login(email)
#     Monk::Auth.deliver_link(email: email, link: Monk::Auth.login_link(token), token: token)
#     @sent = true
#     render "auth/login"
#   end
#
#   # The link in the email: callback_path in config/auth.rb.
#   get("/auth/callback/:token") do
#     session = Monk::Auth.redeem(params[:token]) || halt(401, "This link has expired or was already used.")
#     set_session_cookie(session)
#     redirect(session[:redirect_to] || "/")
#   end
#
#   # From a page, a form with the CSRF token:
#   #   <form method="post" action="/auth/logout"><%= csrf_field %><button>Log out</button></form>
#   post("/auth/logout") do
#     require_csrf!
#     log_out!
#     redirect "/login", flash: "You're logged out."
#   end
#
#   get("/me") { json(email: require_user!) }
# end
# monk:end
