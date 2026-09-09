module Monk
  class InvalidMonkEnvError < StandardError
  end

  class InvalidLogLevelError < StandardError
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

  class ScaffoldExistsError < StandardError
  end
end
