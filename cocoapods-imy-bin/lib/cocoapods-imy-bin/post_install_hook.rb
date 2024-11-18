Pod::HooksManager.register('cocoapods-imy-bin', :post_install) do |context|
  # Build Libraries for Distribution YES
  # -no-verify-emitted-module-interface that can be applied to the Other Swift Flags Swift Compiler Flag which disables the module verifier during the build process

  binary_collector = Pod::Config.instance.podfile.binary_collector
  Pod::UI.info "HooksManager Binary Collector #{binary_collector}"

  def process_build_config(target, config)
    xcconfig_path = config.base_configuration_reference&.real_path
    return if xcconfig_path.nil?

    xcconfig_content = File.read(xcconfig_path)

    binary_collector = Pod::Config.instance.podfile.binary_collector
    modified = false
    new_content = xcconfig_content.dup

    if binary_collector[:i_want_to_collect]
      return unless binary_collector[:support_build_for_distribution].include?(target.product_name)

      # Handle BUILD_LIBRARY_FOR_DISTRIBUTION setting
      if !new_content.include?('BUILD_LIBRARY_FOR_DISTRIBUTION')
        new_content << 'BUILD_LIBRARY_FOR_DISTRIBUTION = YES'
        modified = true
      elsif new_content !~ /BUILD_LIBRARY_FOR_DISTRIBUTION\s*=\s*YES/
        new_content.gsub!(/BUILD_LIBRARY_FOR_DISTRIBUTION\s*=.*$/, 'BUILD_LIBRARY_FOR_DISTRIBUTION = YES')
        modified = true
      end

      # Handle OTHER_SWIFT_FLAGS setting
      if !new_content.include?('OTHER_SWIFT_FLAGS')
        new_content << "\nOTHER_SWIFT_FLAGS = -no-verify-emitted-module-interface" 
        modified = true
      elsif !new_content.include?('-no-verify-emitted-module-interface')
        new_content.gsub!(/OTHER_SWIFT_FLAGS\s*=(.*)$/, 'OTHER_SWIFT_FLAGS = \1 -no-verify-emitted-module-interface')
        modified = true
      end
    else
      if new_content.include?('BUILD_LIBRARY_FOR_DISTRIBUTION')
        if new_content !~ /BUILD_LIBRARY_FOR_DISTRIBUTION\s*=\s*NO/
          new_content.gsub!(/BUILD_LIBRARY_FOR_DISTRIBUTION\s*=.*$/, 'BUILD_LIBRARY_FOR_DISTRIBUTION = NO')
          modified = true
        end
      else
        # 默认值为 NO，不需要修改
      end
    end

    xcconfig_content.replace(new_content) if modified

    File.write(xcconfig_path, xcconfig_content)
  end

  product_module_name_map = {}

  if context.respond_to?(:pod_target_subprojects)
    context.pod_target_subprojects&.each do |project|
      project.targets.each do |target|
        next if target.respond_to?(:product_type) && (target.product_type == 'com.apple.product-type.bundle')

        target.build_configurations&.each do |config|
          process_build_config(target, config)

          # 收集 product module name 映射
          if config.name == 'Release'
            product_module_name_map[target.product_name] = config.build_settings['PRODUCT_MODULE_NAME']
          end
        end
      end
    end
  end

  collector = Pod::Command::Bin::Collect.new(CLAide::ARGV.new([]))

  context.umbrella_targets.each do |target|
    target.specs&.each do |spec|
      next unless spec.parent.nil?

      podspec_path = collector.podspec_json_path(spec.name)
      next if podspec_path.nil?

      Pod::UI.puts "--> write binary spec to #{podspec_path}"
      File.write(podspec_path, spec.to_pretty_json)
    end
  end

  # save product module name map to framework collection cache path
  collector.save_product_module_name_map(product_module_name_map)
  collector.save_binary_collector(binary_collector)
end
