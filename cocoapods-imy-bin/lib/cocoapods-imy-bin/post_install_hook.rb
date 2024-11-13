Pod::HooksManager.register('cocoapods-imy-bin', :post_install) do |context|
  # Build Libraries for Distribution YES
  # -no-verify-emitted-module-interface that can be applied to the Other Swift Flags Swift Compiler Flag which disables the module verifier during the build process
  def process_build_config(config)
    xcconfig_path = config.base_configuration_reference&.real_path
    return if xcconfig_path.nil?

    xcconfig_content = File.read(xcconfig_path)

    binary_build_for_distribution = Pod::Config.instance.podfile.binary_build_for_distribution
    modified = false
    new_content = xcconfig_content.dup

    if binary_build_for_distribution
      if new_content.include?('BUILD_LIBRARY_FOR_DISTRIBUTION')
        if new_content !~ /BUILD_LIBRARY_FOR_DISTRIBUTION\s*=\s*YES/
          new_content.gsub!(/BUILD_LIBRARY_FOR_DISTRIBUTION\s*=.*$/, 'BUILD_LIBRARY_FOR_DISTRIBUTION = YES')
          modified = true
        end
      else
        new_content << "BUILD_LIBRARY_FOR_DISTRIBUTION = YES"
        modified = true
      end

      if new_content.include?('OTHER_SWIFT_FLAGS')
        unless new_content.include?('-no-verify-emitted-module-interface')
          new_content.gsub!(/OTHER_SWIFT_FLAGS\s*=(.*)$/, 'OTHER_SWIFT_FLAGS = \1 -no-verify-emitted-module-interface')
          modified = true
        end
      else
        new_content << "\nOTHER_SWIFT_FLAGS = -no-verify-emitted-module-interface"
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

  # 打印日志以便调试
  puts 'HooksManager Configuring BUILD_LIBRARY_FOR_DISTRIBUTION...'

  product_module_name_map = {}

  context.pod_target_subprojects&.each do |project|
    project.targets.each do |target|
      next if target.respond_to?(:product_type) && (target.product_type == 'com.apple.product-type.bundle')

      target.build_configurations&.each do |config|
        process_build_config(config)

        # 收集 product module name 映射
        if config.name == 'Release'
          product_module_name_map[target.product_name] = config.build_settings['PRODUCT_MODULE_NAME']
        end
      end
    end
  end

  # save product module name map to framework collection cache path
  Pod::Command::Bin::Collect.new(CLAide::ARGV.new([])).save_product_module_name_map(product_module_name_map)
end