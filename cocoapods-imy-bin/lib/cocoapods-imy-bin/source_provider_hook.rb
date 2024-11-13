require 'cocoapods-imy-bin/native/sources_manager'
require 'cocoapods/user_interface'

Pod::HooksManager.register('cocoapods-imy-bin', :source_provider) do |context, _|
  sources_manager = Pod::Config.instance.sources_manager
  podfile = Pod::Config.instance.podfile

  if podfile
    # 添加源码私有源 && 二进制私有源
    added_sources = [sources_manager.code_source]
    if podfile.use_binaries? || podfile.use_binaries_selector
      added_sources << sources_manager.binary_source
      added_sources.reverse!
    end
    added_sources.each { |source| context.add_source(source) }
  end
end
