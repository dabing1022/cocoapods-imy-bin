
require 'cocoapods-imy-bin/command/bin/auto'
require 'cocoapods-imy-bin/helpers/upload_helper'
require 'cocoapods-imy-bin/helpers/wxmsg'

module Pod
  class Command
    class Bin < Command
      class Auto < Bin
        self.summary = '打开 workspace 工程.'

        self.arguments = [
          CLAide::Argument.new('NAME.podspec', false)
        ]
        def self.options
          [
            %w[--code-dependencies 使用源码依赖],
            %w[--allow-prerelease 允许使用prerelease的版本],
            %w[--no-clean 保留构建中间产物],
            %w[--framework-output 输出framework文件],
            %w[--no-zip 不压缩静态framework为zip],
            %w[--all-make 对该组件的依赖库，全部制作为二进制组件],
            ['--configuration', 'Build the specified configuration (e.g. Release ). Defaults to Debug'],
            ['--env', '该组件上传的环境 %w[dev debug_iphoneos release_iphoneos]']
          ].concat(Pod::Command::Gen.options).concat(super).uniq
        end

        def initialize(argv)

          @env = argv.option('env') || 'dev'
          CBin.config.set_configuration_env(@env)

          @podspec = argv.shift_argument || find_podspec
          @specification = Specification.from_file(@podspec)

          @code_dependencies = argv.flag?('code-dependencies')
          @allow_prerelease = argv.flag?('allow-prerelease')
          @framework_output = argv.flag?('framework-output', false )
          @clean = argv.flag?('clean', true)
          @zip = argv.flag?('zip', true)
          @all_make = argv.flag?('all-make', false )
          @verbose = argv.flag?('verbose', true)

          @config = argv.option('configuration', 'Debug')
          @additional_args = argv.remainder!

          super
        end

        def validate!
          help! '未找到 podspec文件' unless @podspec
          super
        end

        def run
          @specification = Specification.from_file(@podspec)

          source_specs = run_archive

          report = "#{@specification.name} 二进制构建结果\n"

          fail_push_specs = []
          source_specs.uniq.each do |spec|
            begin
              fail_push_specs << spec unless CBin::Upload::Helper.new(spec, @code_dependencies, @sources).upload
            rescue  Object => exception
              UI.puts exception
              report << exception << "\n"
              fail_push_specs << spec
            end
          end

          if fail_push_specs.any?
            fail_push_specs.uniq.each do |spec|
              UI.warn "【#{spec.name} | #{spec.version}】组件spec push失败 ."
              report << "【#{spec.name} | #{spec.version}】组件spec push失败 ." << "\n"
            end
          end

          success_specs = source_specs - fail_push_specs
          if success_specs.any?
            auto_success = ''
            success_specs.uniq.each do |spec|
              auto_success += "#{spec.name} | #{spec.version}\n"
              UI.warn "===【 #{spec.name} | #{spec.version} 】二进制组件制作完成 ！！！ "
              report << "===【 #{spec.name} | #{spec.version} 】二进制组件制作完成 ！！！ " << "\n"
            end
            puts '==============  auto_success'
            puts auto_success
            ENV['auto_success'] = auto_success

            report << '==============  auto_success' << "\n"
            CBin::WXMsg.send_wechat_group_msg report
          end
          #pod repo update
          UI.section("\nUpdating Spec Repositories\n".yellow) do
            Pod::Command::Bin::Repo::Update.new(CLAide::ARGV.new([])).run
          end

        end

        #制作二进制包

        def run_archive
          argvs = [
            "--sources=#{sources_option(@code_dependencies, @sources)},https:\/\/cdn.cocoapods.org",
            @additional_args
          ]

          argvs << spec_file if spec_file
          argvs.delete(Array.new)

          argvs += ['--no-clean'] unless @clean
          argvs += ['--code-dependencies'] if @code_dependencies
          argvs += ['--verbose'] if @verbose
          argvs += ['--allow-prerelease'] if @allow_prerelease
          argvs += ['--framework-output'] if @framework_output
          argvs += ['--all-make'] if @all_make
          argvs += ["--env=#{@env}"] if @env
          argvs += ["--configuration=#{@config}"]
          
          archive = Pod::Command::Bin::Archive.new(CLAide::ARGV.new(argvs))
          archive.validate!
          source_specs = archive.run
          source_specs
        end


        def code_podsepc_extname
          '.podsepc'
        end

        def binary_podsepc_json
          "#{@specification.name}.binary.podspec.json"
        end

        def binary_template_podsepc
          "#{@specification.name}.binary-template.podspec"
        end

        def template_spec_file
          @template_spec_file ||= begin
                                    if @template_podspec
                                      find_spec_file(@template_podspec)
                                    else
                                      binary_template_spec_file
                                    end
                                  end
        end

        def spec_file
          @spec_file ||= begin
                           if @podspec
                             find_spec_file(@podspec) || @podspec
                           else
                             raise Informative, '当前目录下没有找到可用源码 podspec.' if code_spec_files.empty?

                             spec_file = if @binary
                                           code_spec = Pod::Specification.from_file(code_spec_files.first)
                                           if template_spec_file
                                             template_spec = Pod::Specification.from_file(template_spec_file)
                                           end
                                           create_binary_spec_file(code_spec, template_spec)
                                         else
                                           code_spec_files.first
                                         end
                             spec_file
                           end
                         end
        end

        #Dir.glob 可替代
        def find_podspec
          name = nil
          Pathname.pwd.children.each do |child|
            puts child
            next unless File.file?(child)
            next unless child.extname == '.podspec'

            name = File.basename(child)
            return name unless name.include?('binary-template')
          end
          name
        end

      end
    end
  end
end
