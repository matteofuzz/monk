module Monk
  class InvalidMonkEnvError < StandardError
  end

  class InvalidLogLevelError < StandardError
  end

  # PUBLIC_URL or LIVE_WS_URL present but wrong: refused at Boot
  # (Settings#freeze_registry!), not the first time a link or socket uses it.
  class InvalidSettingError < StandardError
  end

  class DuplicateSettingError < StandardError
  end

  class MissingSettingError < StandardError
  end

  class UnknownSettingError < StandardError
  end

  class SettingsFrozenError < StandardError
  end

  class UnshareableBlockError < StandardError
  end

  class UnshareableModelError < StandardError
  end

  class UnshareableRouteError < StandardError
  end

  class TemplateNotFoundError < StandardError
  end

  class TemplateSyntaxError < StandardError
  end

  class UnsafeRedirectError < StandardError
  end
end
