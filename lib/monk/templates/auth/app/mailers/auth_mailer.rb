# The login email Monk::Auth sends (config/auth.rb's deliver:), through
# Monk::Mail (config/mail.rb). A lambda in a module constant: the deliver:
# hook must be Ractor-shareable, and a lambda built at a file's top level,
# where self isn't, would fail -- the same constraint as
# Monk::Live.authorize blocks.
module AuthMailer
  # Monk::Auth's deliver: hook (config/auth.rb), called by
  # Monk::Auth.deliver_link. The HTML part is
  # app/views/mail/magic_link.erb. Swap the body for SMS or any other
  # channel; see docs/guides/auth.md.
  MAGIC_LINK = lambda do |email:, link:, token:|
    # Development only (a no-op elsewhere): the link on the console, plus a
    # QR code for a phone if rqrcode is in the Gemfile.
    Monk::Auth.log_dev_link(link, subject: email)
    Monk::Mail.deliver(
      to: email,
      subject: "Your login link",
      text: "Here's your login link:\n\n#{link}\n\nIf you didn't ask for it, you can ignore this email.",
      html: Monk::Mail.render("mail/magic_link", link: link),
    )
  end
end
