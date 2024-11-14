

require 'cocoapods'
require 'cocoapods-imy-bin/config/config'

module Pod
  class Source
    # podfile source manager
    class Manager
      # 源码 source
      def code_source
        source_with_name_or_url(CBin.config.code_repo_url)
      end

      # 二进制 source
      def binary_source
        source_with_name_or_url(CBin.config.binary_repo_url)
      end
    end
  end
end
