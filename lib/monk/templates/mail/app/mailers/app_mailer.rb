# The emails this app sends, through Monk::Mail (config/mail.rb). Module
# methods, so a route or a job can call them from any Ractor.
module AppMailer
  # monk:example mail-welcome -- an email, sent from a route (app/routes/mail.rb).
  # def self.welcome(to:, name:)
  #   Monk::Mail.deliver(
  #     to: to,
  #     subject: "Welcome, #{name}",
  #     text: "Hello #{name}, thanks for signing up.",
  #     html: Monk::Mail.render("mail/welcome", name: name),
  #   )
  # end
  # monk:end
end
