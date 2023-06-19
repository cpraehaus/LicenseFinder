# frozen_string_literal: true

require 'json'
require 'tempfile'

module LicenseFinder
  class NPM < PackageManager
    def current_packages
      NpmPackage.packages_from_json(npm_json, detected_package_path)
    end

    def package_management_command
      'npm --legacy-peer-deps'
    end

    def prepare_command
      # --legacy-peer-deps to workaround https://github.com/npm/cli/issues/3666
      # to work with node 18 and npm 9
      'npm install --no-save --ignore-scripts --legacy-peer-deps'
    end

    def possible_package_paths
      [project_path.join('package.json')]
    end

    def prepare
      prep_cmd = "#{prepare_command}#{production_flag}"
      _stdout, stderr, status = Dir.chdir(project_path) { Cmd.run(prep_cmd) }

      return if status.success?

      log_errors stderr
      raise "Prepare command '#{prep_cmd}' failed" unless @prepare_no_fail
    end

    private

    def npm_json
      command = "#{package_management_command} list --json --long#{all_flag}#{production_flag}"
      command += " #{@npm_options}" unless @npm_options.nil?
      stdout, stderr, status = Dir.chdir(project_path) { Cmd.run(command) }
      # we can try and continue if we got an exit status 1 - unmet peer dependency
      raise "Command '#{command}' failed to execute: #{stderr}" if !status.success? && status.exitstatus != 1

      JSON.parse(stdout)
    end

    def production_flag
      return '' if @ignored_groups.nil?

      # NOTE: newer npm vers use --omit=dev instead of --production
      @ignored_groups.include?('devDependencies') ? ' --omit=dev' : ''
    end

    def production_flag
      return '' if @ignored_groups.nil?
      prod_flag = npm_version >= 9 ? ' --omit=dev' : ' --production'

      @ignored_groups.include?('devDependencies') ? prod_flag : ''
    end

    def all_flag
      npm_version >= 7 ? ' --all' : ''
    end

    def npm_version
      command = "#{package_management_command} -v"
      stdout, stderr, status = Dir.chdir(project_path) { Cmd.run(command) }
      raise "Command '#{command}' failed to execute: #{stderr}" unless status.success?

      version = stdout.split('.').map(&:to_i)
      version[0]
    end
  
  end
end
