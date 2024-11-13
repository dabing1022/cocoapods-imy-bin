require 'cocoapods-imy-bin/helpers/binary_spec_creator'

module Pod
  class Command
    class Bin < Command
      # 静态库归档
      class Collect < Bin
        self.summary = '静态库Framework收集'
        self.description = <<-DESC
            将组件归档为静态库 framework
        DESC

        self.arguments = [
          CLAide::Argument.new('pods_list', true)
        ]

        def self.options
          [].concat(Pod::Command::Framework::Collect.options).concat(super).uniq
        end

        def initialize(argv)
          @pod_list = argv.shift_argument&.split(',') || []

          super
          @additional_args = argv.remainder!
        end

        def run
          # 需要到构建产物的目录来查找构建的产物
          # /Users/childhoodandy/Library/Developer/Xcode/DerivedData/zhuanzhuan-celrvxnhshslubcbmolkalxerwvc/Build/Products/Debug-iphoneos
          # Debug-iphoneos, Release-iphoneos, Debug-iphonesimulator, Release-iphonesimulator
          # echo "BUILT_PRODUCTS_DIR: ${BUILT_PRODUCTS_DIR}"
          # echo "BUILD_DIR ${BUILD_DIR}"
          # echo "BUILD_ROOT ${BUILD_ROOT}"
          @build_products_dir = ENV['XCODE_BUILT_PRODUCTS_DIR']
          # such as: iphoneos, iphonesimulator
          @build_configuration = Pathname.new(@build_products_dir).basename.to_s.split('-').last

          puts "xcode: build_products_dir: #{@build_products_dir}"

          clean_collection_cache

          @pod_list.each do |pod_name|
            framework_path = collect_framework pod_name
            next if framework_path.nil?

            create_xcframework(pod_name, framework_path)
            generate_binary_podspec(pod_name)
          end
        end

        # 清理整个收集缓存目录
        def clean_collection_cache
          FileUtils.rm_rf(collection_cache_path) if Dir.exist?(collection_cache_path)
        end

        # 清理指定pod的收集缓存目录
        def clean_pod_collection_cache(pod_name)
          FileUtils.rm_rf(File.join(collection_cache_path, pod_name)) if Dir.exist?(File.join(collection_cache_path, pod_name))
        end

        def collect_framework(pod_name)
          pod_framework_path = copy_lib pod_name
          copy_headers pod_name
          copy_swift_compatibility_header pod_name
          copy_modules pod_name
          copy_resources pod_name
          copy_swiftmodule pod_name

          pod_framework_path
        end

        def create_xcframework(pod_name, framework_path)
          pod_collection_cache_dir = pod_collection_cache_dir(pod_name)
          xcframework_path = File.join(pod_collection_cache_dir, File.basename(framework_path).gsub('.framework', '.xcframework'))
          `xcodebuild -create-xcframework -framework #{framework_path} -output #{xcframework_path}`
        end

        def copy_lib(pod_name)
          lib_path = pod_lib_path(pod_name)
          return nil if lib_path.nil?

          pod_framework_path = pod_collection_framework_path(pod_name)

          product_name = pod_product_name(pod_name)
          FileUtils.cp(lib_path, File.join(pod_framework_path, product_name))

          pod_framework_path
        end

        def copy_headers(pod_name)
          sandbox_path = Pod::Config.instance.sandbox.root
          product_name = pod_product_name(pod_name)
          pod_headers = File.join(sandbox_path, 'Headers', 'Public', product_name)
          framework_header_dir = pod_collection_framework_headers_dir pod_name

          Dir.glob(File.join(pod_headers, '*')).each do |header|
            next if File.basename(header).include?('.modulemap')

            if File.symlink?(header)
              real_header = File.realpath(header)
              FileUtils.cp_r(real_header, framework_header_dir)
            else
              FileUtils.cp_r(header, framework_header_dir)
            end
          end
        end

        def copy_swift_compatibility_header(pod_name)
          compatibility_header_path = pod_compatibility_header_path(pod_name)
          return nil if compatibility_header_path.nil?

          Dir.glob(File.join(compatibility_header_path, '*')).each do |header|
            FileUtils.cp_r(header, pod_collection_framework_headers_dir(pod_name))
          end
        end

        def copy_modules(pod_name)
          sandbox_path = Pod::Config.instance.sandbox.root
          pod_headers = File.join(sandbox_path, 'Headers', 'Public', pod_name)
          framework_modules_dir = pod_collection_framework_modules_dir pod_name

          modulemap_files = Dir.glob(File.join(pod_headers, '*.modulemap'))
          product_name = pod_product_name(pod_name)
          if modulemap_files.empty?
            # Generate manual modulemap if none exists
            modulemap_content = <<~MODULEMAP
              module #{product_name} {
                umbrella header "#{product_name}-umbrella.h"
              #{'  '}
                export *
                module * { export * }
              }
            MODULEMAP
            File.write("#{framework_modules_dir}/module.modulemap", modulemap_content)
          else
            # Copy existing modulemap
            modulemap_files.each do |header|
              if File.symlink?(header)
                real_header = File.realpath(header)
                FileUtils.cp_r(real_header, "#{framework_modules_dir}/module.modulemap")
              else
                FileUtils.cp_r(header, "#{framework_modules_dir}/module.modulemap")
              end
            end
          end
        end

        def copy_resources(pod_name)
          resources_path = pod_resources_path(pod_name)
          return nil if resources_path.nil?

          framework_resources_dir = pod_collection_framework_resources_dir pod_name
          FileUtils.cp_r(resources_path, framework_resources_dir)
        end

        def copy_swiftmodule(pod_name)
          swiftmodule_path = pod_swiftmodule_path(pod_name)
          return nil if swiftmodule_path.nil?

          pod_collection_modules_dir = pod_collection_framework_modules_dir(pod_name)
          FileUtils.cp_r(swiftmodule_path, pod_collection_modules_dir)
          swiftmodule_name = File.basename(swiftmodule_path)

          # 删除Project目录
          project_swiftmodule_path = File.join(pod_collection_modules_dir, swiftmodule_name, 'Project')
          FileUtils.rm_rf(project_swiftmodule_path) if Dir.exist?(project_swiftmodule_path)
        end

        # 生成二进制 podspec
        def generate_binary_podspec(pod_name)
          spec_json_path = podspec_json_path(pod_name)
          return nil if spec_json_path.nil?

          binary_spec_creator = CBin::BinarySpecification::Creator.new(spec_json_path)
          target_binary_spec_path = File.join(pod_collection_cache_dir(pod_name), "#{pod_name}.binary.podspec.json")
          binary_spec_creator.write_binary_spec(target_binary_spec_path)
        end

        def pod_product_name(pod_name)
          product_module_map_json[pod_name] || pod_name
        end

        # 获取pod的lib路径
        def pod_lib_path(pod_name)
          pod_product_dir = File.join(@build_products_dir, pod_name)
          return nil unless Dir.exist?(pod_product_dir)

          Dir.chdir(pod_product_dir) do
            a_files = Dir.glob('*.a')
            return nil if a_files.empty?

            File.join(pod_product_dir, a_files.first)
          end
        end

        def pod_compatibility_header_path(pod_name)
          pod_product_dir = File.join(@build_products_dir, pod_name)
          return nil unless Dir.exist?(pod_product_dir)

          Dir.chdir(pod_product_dir) do
            compatibility_header_path = Dir.glob('Swift Compatibility Header')
            return nil if compatibility_header_path.empty?

            File.join(pod_product_dir, compatibility_header_path.first)
          end
        end

        def pod_resources_path(pod_name)
          pod_product_dir = File.join(@build_products_dir, pod_name)
          return nil unless Dir.exist?(pod_product_dir)

          Dir.chdir(pod_product_dir) do
            resources_path = Dir.glob('*.bundle')
            return nil if resources_path.empty?

            File.join(pod_product_dir, resources_path.first)
          end
        end

        def pod_swiftmodule_path(pod_name)
          pod_product_dir = File.join(@build_products_dir, pod_name)
          return nil unless Dir.exist?(pod_product_dir)

          Dir.chdir(pod_product_dir) do
            swiftmodule_path = Dir.glob('*.swiftmodule')
            return nil if swiftmodule_path.empty?

            File.join(pod_product_dir, swiftmodule_path.first)
          end
        end

        def collection_cache_path
          cache_path ||= begin
            cache_path = File.join(Pod::Config.instance.sandbox.root.to_s, 'FrameworkCollections')
            FileUtils.mkdir_p(cache_path) unless Dir.exist?(cache_path)
            cache_path
          end
        end

        def save_product_module_name_map(product_module_name_map)
          File.write(product_module_map_json_path, JSON.pretty_generate(product_module_name_map))
        end

        def product_module_map_json
          return {} unless File.exist?(product_module_map_json_path)

          @product_module_map_json ||= JSON.parse(File.read(product_module_map_json_path))
        end

        def product_module_map_json_path
          File.join(Pod::Config.instance.sandbox.root.to_s, 'product_module_name_map.json')
        end

        def pod_collection_cache_dir(pod_name)
          cache_dir ||= begin
            cache_dir = File.join(collection_cache_path, pod_name)
            FileUtils.mkdir_p(cache_dir) unless Dir.exist?(cache_dir)
            cache_dir
          end
        end

        def pod_collection_framework_path(pod_name)
          framework_path ||= begin
            product_name = pod_product_name(pod_name)
            framework_path = File.join(pod_collection_cache_dir(pod_name), @build_configuration, "#{product_name}.framework")
            FileUtils.mkdir_p(framework_path) unless Dir.exist?(framework_path)
            framework_path
          end
        end

        def pod_collection_framework_headers_dir(pod_name)
          headers_path ||= begin
            headers_path = File.join(pod_collection_framework_path(pod_name), 'Headers')
            FileUtils.mkdir_p(headers_path) unless Dir.exist?(headers_path)
            headers_path
          end
        end

        def pod_collection_framework_modules_dir(pod_name)
          modules_path ||= begin
            modules_path = File.join(pod_collection_framework_path(pod_name), 'Modules')
            FileUtils.mkdir_p(modules_path) unless Dir.exist?(modules_path)
            modules_path
          end
        end

        def pod_collection_framework_resources_dir(pod_name)
          resources_path ||= begin
            resources_path = File.join(pod_collection_framework_path(pod_name), 'Resources')
            FileUtils.mkdir_p(resources_path) unless Dir.exist?(resources_path)
            resources_path
          end
        end

        def podspec_json_path(pod_name)
          podspec_json_path = File.join(cbin_local_podspecs_dir, "#{pod_name}.podspec.json")
          return nil unless File.exist?(podspec_json_path)

          podspec_json_path
        end

        def cbin_local_podspecs_dir
          @cbin_local_podspecs_dir ||= begin
            sandbox_path = Pod::Config.instance.sandbox.root
            cbin_local_podspecs_dir = File.join(sandbox_path, 'CBin Local Podspecs')
            FileUtils.mkdir_p(cbin_local_podspecs_dir) unless Dir.exist?(cbin_local_podspecs_dir)
            cbin_local_podspecs_dir
          end
        end

        def build_xcframework(pod_name)
          # 1. 找到对应的framework
          # 2. 拷贝到指定的目录
          # 3. 修改framework的名字
          # 4. 修改framework的引用
          # 5. 使用xcodebuild -create-xcframework命令创建xcframework
        end

        def zip_xcframework(pod_name)


        end

        def upload_zip(zip_file)

        end

      end
    end
  end
end
