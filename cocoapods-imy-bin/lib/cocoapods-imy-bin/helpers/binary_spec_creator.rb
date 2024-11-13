module CBin
  class BinarySpecification
    # 二进制 podspec 的创建，用于 command: collect 收集项目组装 xcframework 之后，生成二进制 podspec
    class Creator
      attr_reader :local_spec, :collector

      def initialize(spec_json_path)
        @local_spec = Pod::Specification.from_file(spec_json_path)
        @collector = Pod::Command::Bin::Collect.new(CLAide::ARGV.new([]))
      end

      def write_binary_spec(target_spec_path)
        process_local_spec

        File.open(target_spec_path, 'w+') do |f|
          f.write(local_spec.to_pretty_json)
        end
      end

      private

      def module_name_map
        @module_name_map ||= collector.product_module_map_json
      end

      def process_local_spec
        spec_hash = local_spec.to_hash
        process_vendored_frameworks(spec_hash)
        process_source(spec_hash)
        process_resources(spec_hash)
        process_source_files(spec_hash)
        process_exclude_files(spec_hash)
        process_preserve_paths(spec_hash)
        process_vendored_libraries(spec_hash)
        @local_spec = Pod::Specification.from_hash(spec_hash)
      end

      def process_source(spec_hash)
        spec_hash['source'] = binary_source
      end

      def process_vendored_frameworks(spec_hash)
        module_name = module_name_map[local_spec.name]
        if spec_hash['vendored_frameworks'].nil?
          local_spec.vendored_frameworks = "#{module_name}.xcframework"
        else
          # If vendored_frameworks is a string, convert to array
          existing_frameworks = spec_hash['vendored_frameworks'].is_a?(String) ? [spec_hash['vendored_frameworks']] : spec_hash['vendored_frameworks']
          # Add new xcframework while preserving existing ones
          spec_hash['vendored_frameworks'] = existing_frameworks + ["#{module_name}.xcframework"]
        end
      end

      def process_resources(spec_hash)
        spec_hash.delete('resource_bundles')
        spec_hash.delete('resources')
      end

      def process_exclude_files(spec_hash)
        spec_hash.delete('exclude_files')
      end

      def process_preserve_paths(spec_hash)
        spec_hash.delete('preserve_paths')
      end

      def process_vendored_libraries(spec_hash)
        spec_hash.delete('vendored_libraries')
      end

      def process_source_files(spec_hash)
        spec_hash.delete('source_files')
        spec_hash.delete('public_header_files')
      end

      def binary_source
        { http: format(CBin.config.binary_download_url, local_spec.root.name, local_spec.version), type: CBin.config.download_file_type }
      end

    end

  end

end