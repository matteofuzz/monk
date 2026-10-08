# Routes that send email (monk add mail).
#
# monk:example mail-welcome -- the route that sends AppMailer.welcome
# # (app/mailers/app_mailer.rb). Sending waits for the mail server; with
# # monk add jobs, send it from a job instead (AGENTS.md, mail).
# class App
#   post("/welcome") do
#     AppMailer.welcome(to: params[:email].to_s, name: params[:name].to_s)
#     json(sent: true)
#   end
# end
# monk:end
