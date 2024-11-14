require 'cocoapods-imy-bin/helpers/binary_spec_creator'
require 'cocoapods-imy-bin/helpers/wxmsg'

module Pod
  class Command
    class Bin < Command
       # 静态库归档
      class Collect < Bin
        include CBin::SourcesHelper

        self.summary = '静态库Framework收集'
        self.description = <<-DESC
            将组件归档为静态库 framework
        DESC

        self.arguments = [
          CLAide::Argument.new('pods_list', true)
        ]

        BINARY_COLLECTIONS_DIR = 'BinaryCollections'.freeze

        def self.options
          [
            %w[--no_publish 不推送二进制到文件服务器以及是否推送二进制 podspec],
            %w[--override_binary 是否推送二进制覆盖已有的二进制]
          ].concat(Pod::Command::Framework::Collect.options).concat(super).uniq
        end

        def initialize(argv)
          @pod_list = argv.shift_argument&.split(',') || []
          @no_publish = argv.flag?('no_publish', false)
          @override_binary = argv.flag?('override_binary', false)
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
          if @build_products_dir.nil?
            Pod::UI.warn '=================================================================================================='
            Pod::UI.warn '未找到构建产物目录，请确认是否在环境变量中设置了 XCODE_BUILT_PRODUCTS_DIR (export XCODE_BUILT_PRODUCTS_DIR=xxx)'
            Pod::UI.warn '=================================================================================================='
            return
          end
          # such as: iphoneos, iphonesimulator
          @build_configuration = Pathname.new(@build_products_dir).basename.to_s.split('-').last
          if @build_configuration.nil?
            Pod::UI.warn '=================================================================================================='
            Pod::UI.warn "#{@build_products_dir} 不是一个有效的构建产物目录"
            Pod::UI.warn '=================================================================================================='
          end

          Pod::UI.notice "Xcode: build_products_dir: #{@build_products_dir}"

          clean_collection_cache

          @pod_list.each do |pod_name|
            Pod::UI.section("Binary Collecting #{pod_name}") do
              framework_path = collect_framework pod_name
              next if framework_path.nil?

              xcframework_path = create_xcframework(pod_name, framework_path)
              zip_path = zip_xcframework(pod_name, xcframework_path)
              upload_zip(pod_name, zip_path) unless @no_publish

              binary_spec_json_path = generate_binary_podspec(pod_name)
              push_binary_repo(binary_spec_json_path) unless @no_publish

              unless @no_publish
                spec = spec_of_pod(pod_name)
                next if spec.nil?

                Pod::UI.notice "Binary Collecting #{spec.name} #{spec.version} finished"

                msg = "#{spec.name} -> #{spec.version} 二进制组件制作完成！"
                # CBin::WXMsg.send_wechat_group_msg(msg)
              end
            end
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
          pod_framework_path = Pod::UI.info('-> Copying library') do
            copy_lib(pod_name)
          end

          copy_steps = {
            'headers' => :copy_headers,
            'umbrella header' => :copy_umbrella_header,
            'Swift compatibility header' => :copy_swift_compatibility_header,
            'modules' => :copy_modules,
            'resources' => :copy_resources,
            'Swift module' => :copy_swiftmodule
          }

          copy_steps.each do |component, method|
            Pod::UI.info("-> Copying #{component}") do
              send(method, pod_name)
            end
          end

          pod_framework_path
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

        def podspec_json_path(pod_name)
          podspec_json_path = File.join(cbin_local_podspecs_dir, "#{pod_name}.podspec.json")
          return nil unless File.exist?(podspec_json_path)

          podspec_json_path
        end

        private

        def create_xcframework(pod_name, framework_path)
          pod_collection_cache_dir = pod_collection_cache_dir(pod_name)
          xcframework_path = File.join(pod_collection_cache_dir, File.basename(framework_path).gsub('.framework', '.xcframework'))
          `xcodebuild -create-xcframework -framework #{framework_path} -output #{xcframework_path}`

          xcframework_path
        end

        def copy_lib(pod_name)
          lib_path = pod_lib_path(pod_name)
          if lib_path.nil?
            pod_product_dir = pod_product_dir(pod_name)
            path = File.join(pod_product_dir, "lib#{pod_name}.a")
            Pod::UI.warn "未找到 #{pod_name} 的构建产物 #{path}"
            return
          end

          pod_framework_path = pod_collection_framework_path(pod_name)

          product_name = pod_product_name(pod_name)
          FileUtils.cp(lib_path, File.join(pod_framework_path, product_name))

          pod_framework_path
        end

        def copy_headers(pod_name)
          sandbox_path = Pod::Config.instance.sandbox.root
          product_name = pod_product_name(pod_name)
          pod_headers = File.join(sandbox_path.to_s, 'Headers', 'Public', product_name)
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
          pod_headers = File.join(sandbox_path.to_s, 'Headers', 'Public', pod_name)
          framework_modules_dir = pod_collection_framework_modules_dir pod_name

          modulemap_files = Dir.glob(File.join(pod_headers, '*.modulemap'))
          product_name = pod_product_name(pod_name)
          if modulemap_files.empty?
            # Generate manual modulemap if none exists
            # 注意这里要使用 framework module 而不是 module, 否则会找不到 umbrella header
            modulemap_content = <<~MODULEMAP
              framework module #{product_name} {
                umbrella header "#{product_name}-umbrella.h"
              #{'  '}
                export *
                module * { export * }
              }
            MODULEMAP
            File.write("#{framework_modules_dir}/module.modulemap", modulemap_content)
          else
            # Copy existing modulemap
            target_header = File.join(framework_modules_dir, 'module.modulemap')
            modulemap_files.each do |header|
              if File.symlink?(header)
                real_header = File.realpath(header)
                FileUtils.cp_r(real_header, target_header)
              else
                FileUtils.cp_r(header, target_header)
              end
              # modify modulemap content
              modulemap_content = File.read(target_header)
              # Only replace 'module' if it's not already 'framework module'
              modulemap_content.sub!(/(?<!framework\s)module/, 'framework module')
              File.write(target_header, modulemap_content)
            end
          end
        end

        def copy_umbrella_header(pod_name)
          sandbox_path = Pod::Config.instance.sandbox.root
          pod_headers = File.join(sandbox_path.to_s, 'Headers', 'Public', pod_name)
          framework_header_dir = pod_collection_framework_headers_dir pod_name

          umbrella_header_files = Dir.glob(File.join(pod_headers, '*-umbrella.h'))
          product_name = pod_product_name(pod_name)
          if umbrella_header_files.empty?
            # Generate manual umbrella header if none exists
            import_header_statements = Dir.glob(File.join(pod_headers, '*.{h,hpp,hxx,hh}')).map { |header| "#import \"#{File.basename(header)}\"" }.join("\n")
            # only support iphoneos
            umbrella_header_content = <<~UMBRELLA_HEADER
#ifdef __OBJC__
#import <UIKit/UIKit.h>
#else
#ifndef FOUNDATION_EXPORT
#if defined(__cplusplus)
#define FOUNDATION_EXPORT extern "C"
#else
#define FOUNDATION_EXPORT extern
#endif
#endif
#endif

// auto generated by cocoapods-imy-bin

#{import_header_statements}

FOUNDATION_EXPORT double #{product_name}VersionNumber;
FOUNDATION_EXPORT const unsigned char #{product_name}VersionString[];
            UMBRELLA_HEADER
            File.write("#{framework_header_dir}/#{pod_name}-umbrella.h", umbrella_header_content)
          else
            # Copy existing umbrella header
            umbrella_header_files.each do |header|
              if File.symlink?(header)
                real_header = File.realpath(header)
                FileUtils.cp_r(real_header, "#{framework_header_dir}/#{pod_name}-umbrella.h")
              else
                FileUtils.cp_r(header, "#{framework_header_dir}/#{pod_name}-umbrella.h")
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

          target_binary_spec_path
        end

        def pod_product_name(pod_name)
          product_module_map_json[pod_name] || pod_name
        end

        def pod_product_dir(pod_name)
          File.join(@build_products_dir, pod_name)
        end

        # 获取pod的lib路径
        def pod_lib_path(pod_name)
          pod_product_dir = pod_product_dir(pod_name)
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
          cache_path = File.join(Pod::Config.instance.sandbox.root.to_s, BINARY_COLLECTIONS_DIR)
          FileUtils.mkdir_p(cache_path) unless Dir.exist?(cache_path)
          cache_path
        end

        def pod_collection_cache_dir(pod_name)
          cache_dir = File.join(collection_cache_path, pod_name)
          FileUtils.mkdir_p(cache_dir) unless Dir.exist?(cache_dir)
          cache_dir
        end

        def pod_collection_framework_path(pod_name)
          product_name = pod_product_name(pod_name)
          framework_path = File.join(pod_collection_cache_dir(pod_name), @build_configuration, "#{product_name}.framework")
          FileUtils.mkdir_p(framework_path) unless Dir.exist?(framework_path)
          framework_path
        end

        def pod_collection_framework_headers_dir(pod_name)
          headers_path = File.join(pod_collection_framework_path(pod_name), 'Headers')
          FileUtils.mkdir_p(headers_path) unless Dir.exist?(headers_path)
          headers_path
        end

        def pod_collection_framework_modules_dir(pod_name)
          modules_path = File.join(pod_collection_framework_path(pod_name), 'Modules')
          FileUtils.mkdir_p(modules_path) unless Dir.exist?(modules_path)
          modules_path
        end

        def pod_collection_framework_resources_dir(pod_name)
          resources_path = File.join(pod_collection_framework_path(pod_name), 'Resources')
          FileUtils.mkdir_p(resources_path) unless Dir.exist?(resources_path)
          resources_path
        end

        def cbin_local_podspecs_dir
          @cbin_local_podspecs_dir ||= begin
            sandbox_path = Pod::Config.instance.sandbox.root
            cbin_local_podspecs_dir = File.join(sandbox_path, 'CBin Local Podspecs')
            FileUtils.mkdir_p(cbin_local_podspecs_dir) unless Dir.exist?(cbin_local_podspecs_dir)
            cbin_local_podspecs_dir
          end
        end

        def zip_xcframework(pod_name, xcframework_path)
          pod_collection_cache_dir = pod_collection_cache_dir(pod_name)
          xcframework_zip_path = File.join(pod_collection_cache_dir, "#{pod_name}.zip")
          Dir.chdir(File.dirname(xcframework_path)) do
            `zip --symlinks -r #{xcframework_zip_path} #{File.basename(xcframework_path)}`
          end

          xcframework_zip_path
        end

        def spec_of_pod(pod_name)
          spec_file = podspec_json_path(pod_name)
          return nil if spec_file.nil?

          Pod::Specification.from_file(spec_file)
        end

        # 推送二进制
        # curl http://ci.xxx:9192/frameworks -F "name=IMYFoundation" -F "version=7.7.4.2" -F "annotate=IMYFoundation_7.7.4.2_log" -F "file=@bin-zip/bin_IMYFoundation_7.7.4.2.zip"
        def upload_zip(pod_name, zip_file)
          unless File.exist?(zip_file)
            Pod::UI.warn "未找到需要上传的文件: #{zip_file}"
            return
          end

          delete_binary(pod_name) if @override_binary

          spec = spec_of_pod(pod_name)
          return if spec.nil?

          upload_url = CBin.config.binary_upload_url
          command = "curl #{upload_url} -F \"name=#{spec.name}\" " \
                    "-F \"version=#{spec.version}\" " \
                    "-F \"annotate=#{spec.name}_#{spec.version}_log\" " \
                    "-F \"file=@#{zip_file}\""

          Pod::UI.notice <<~EOF
            上传二进制文件
            #{command}
          EOF

          upload_result = `#{command}`
          Pod::UI.info upload_result
          upload_result
        end

        def delete_binary(pod_name)
          # binary_download_url: http://binary.zhuaninc.com/frameworks/%s/%s/zip
          # curl -v -X DELETE http://binary.zhuaninc.com/frameworks/lottie-ios/2.1.8-stable+zhuanzhuan
          spec = spec_of_pod(pod_name)
          return if spec.nil?

          upload_url = CBin.config.binary_upload_url
          full_url = "#{upload_url}/#{spec.name}/#{spec.version}"
          command = "curl -v -X DELETE #{full_url}"
          Pod::UI.notice <<~EOF
            删除二进制文件
            #{command}
          EOF

          delete_result = `#{command}`
          Pod::UI.info delete_result
          delete_result
        end

        # 上传二进制 podspec
        def push_binary_repo(binary_podspec_json)
          argv = [
            binary_podspec_json.to_s,
            '--binary',
            "--sources=#{binary_source}",
            '--skip-import-validation',
            '--use-libraries',
            '--allow-warnings',
            '--code-dependencies'
          ]
          argv += ['--verbose'] if @verbose

          push = Pod::Command::Bin::Repo::Push.new(CLAide::ARGV.new(argv))
          push.validate!
          push.run
        end

      end
    end
  end
end
