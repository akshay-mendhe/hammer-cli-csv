# Copyright (c) 2013 Red Hat
#
# MIT License
#
# Permission is hereby granted, free of charge, to any person obtaining
# a copy of this software and associated documentation files (the
# "Software"), to deal in the Software without restriction, including
# without limitation the rights to use, copy, modify, merge, publish,
# distribute, sublicense, and/or sell copies of the Software, and to
# permit persons to whom the Software is furnished to do so, subject to
# the following conditions:
#
# The above copyright notice and this permission notice shall be
# included in all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
# EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
# MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
# NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
# LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
# OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
# WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
#
#

require 'hammer_cli'
require 'katello_api'
require 'foreman_api'
require 'json'
require 'csv'

module HammerCLICsv
  class BaseCommand < HammerCLI::AbstractCommand

    HEADERS = {'Accept' => 'version=2,application/json'}

    option ["-v", "--verbose"], :flag, "be verbose"
    option ['--threads'], 'THREAD_COUNT', 'Number of threads to hammer with', :default => 1
    option ['--csv-export'], :flag, 'Export current data instead of importing'
    option ['--csv-file'], 'FILE_NAME', 'CSV file (default to /dev/stdout with --csv-export, otherwise required)'
    option ['--katello'], :flag, 'Use katello'
    option ['--foreman'], :flag, 'Use foreman'
    option ['--server'], 'SERVER', 'Server URL'
    option ['-u', '--username'], 'USERNAME', 'Username to access server'
    option ['-p', '--password'], 'PASSWORD', 'Password to access server'

    def execute
      if !csv_file
        csv_file = '/dev/stdout' if csv_export? # TODO: how to get this to actually set value?
        signal_usage_error "--csv-file required" if !csv_file
      end
      signal_usage_error "--katello and --foreman cannot both be specified" if katello? && foreman?
      signal_usage_error "one of --katello or --foreman required" if !katello? && !foreman?

      @init_options = {
        :base_url => server   || (katello? ? HammerCLI::Settings.get(:katello, :host) :
                                             HammerCLI::Settings.get(:foreman, :host)),
        :username => username || (katello? ? HammerCLI::Settings.get(:katello, :username) :
                                             HammerCLI::Settings.get(:foreman, :username)),
        :password => password || (katello? ? HammerCLI::Settings.get(:katello, :password) :
                                             HammerCLI::Settings.get(:foreman, :password))
      }

      if katello?
        # TODO
        @k_user_api ||= KatelloApi::Resources::User.new(@init_options)
        @k_organization_api ||= KatelloApi::Resources::Organization.new(@init_options)
      else
        @f_architecture_api ||= ForemanApi::Resources::Architecture.new(@init_options)
        @f_domain_api ||= ForemanApi::Resources::Domain.new(@init_options)
        @f_environment_api ||= ForemanApi::Resources::Environment.new(@init_options)
        @f_host_api ||= ForemanApi::Resources::Host.new(@init_options)
        @f_operatingsystem_api ||= ForemanApi::Resources::OperatingSystem.new(@init_options)
        @f_organization_api ||= ForemanApi::Resources::Organization.new(@init_options)
        @f_ptable_api ||= ForemanApi::Resources::Ptable.new(@init_options)
        @f_user_api ||= ForemanApi::Resources::User.new(@init_options)
      end
    end

    def get_lines(filename)
      file = File.open(filename ,'r')
      contents = file.readlines
      file.close
      contents
    end

    def namify(name_format, number)
      if name_format.index('%')
        name_format % number
      else
        name_format
      end
    end

    def thread_import
      csv = []
      CSV.foreach(csv_file, {:skip_blanks => true, :headers => :first_row, :return_headers => false}) do |line|
        csv << line
      end
      lines_per_thread = csv.length/threads.to_i + 1
      splits = []

      threads.to_i.times do |current_thread|
        start_index = ((current_thread) * lines_per_thread).to_i
        finish_index = ((current_thread + 1) * lines_per_thread).to_i
        lines = csv[start_index...finish_index].clone
        splits << Thread.new do
          lines.each do |line|
            if line.index('#') != 0
              yield line
            end
          end
        end
      end

      splits.each do |thread|
        thread.join
      end
    end

    def foreman_organization(options={})
      @organizations ||= {}

      if options[:name]
        options[:id] = @organizations[options[:name]]
        if !options[:id]
          organization = @f_organization_api.index({'search' => "name=\"#{options[:name]}\""}, HEADERS)[0]
          options[:id] = organization[0]['organization']['id']
          @organizations[options[:name]] = options[:id]
        end
        result = options[:id]
      else
        options[:name] = @organizations.key(options[:id])
        if !options[:name]
          organization = @f_organization_api.show({'id' => options[:id]}, HEADERS)[0]
          options[:name] = organization['organization']['name']
          @organizations[options[:name]] = options[:id]
        end
        result = options[:name]
      end

      result
    end

    def foreman_environment(options={})
      @environments ||= {}

      if options[:name]
        options[:id] = @environments[options[:name]]
        if !options[:id]
          environment = @f_environment_api.index({'search' => "name=\"#{options[:name]}\""}, HEADERS)[0]
          options[:id] = environment[0]['environment']['id']
          @environments[options[:name]] = options[:id]
        end
        result = options[:id]
      else
        options[:name] = @environments.key(options[:id])
        if !options[:name]
          environment = @f_environment_api.show({'id' => options[:id]}, HEADERS)[0]
          options[:name] = environment['environment']['name']
          @environments[options[:name]] = options[:id]
        end
        result = options[:name]
      end

      result
    end

    def foreman_operatingsystem(options={})
      @operatingsystems ||= {}

      if options[:name]
        options[:id] = @operatingsystems[options[:name]]
        if !options[:id]
          (osname, major, minor) = split_os_name(options[:name])
          search = "name=\"#{osname}\" and major=\"#{major}\" and minor=\"#{minor}\""
          operatingsystems = @f_operatingsystem_api.index({'search' => search}, HEADERS)[0]
          options[:id] = operatingsystems[0]['operatingsystem']['id']
          @operatingsystems[options[:name]] = options[:id]
        end
        result = options[:id]
      else
        options[:name] = @operatingsystems.key(options[:id])
        if !options[:name]
          operatingsystem = @f_operatingsystem_api.show({'id' => options[:id]}, HEADERS)[0]
          options[:name] = build_os_name(operatingsystem['operatingsystem']['name'],
                                         operatingsystem['operatingsystem']['major'],
                                         operatingsystem['operatingsystem']['minor'])
          @operatingsystems[options[:name]] = options[:id]
        end
        result = options[:name]
      end

      result
    end

    def foreman_architecture(options={})
      @architectures ||= {}

      if options[:name]
        options[:id] = @architectures[options[:name]]
        if !options[:id]
          architecture = @f_architecture_api.index({'search' => "name=\"#{options[:name]}\""}, HEADERS)[0]
          options[:id] = architecture[0]['architecture']['id']
          @architectures[options[:name]] = options[:id]
        end
        result = options[:id]
      else
        options[:name] = @architectures.key(options[:id])
        if !options[:name]
          architecture = @f_architecture_api.show({'id' => options[:id]}, HEADERS)[0]
          options[:name] = architecture['architecture']['name']
          @architectures[options[:name]] = options[:id]
        end
        result = options[:name]
      end

      result
    end

    def foreman_domain(options={})
      @domains ||= {}

      if options[:name]
        options[:id] = @domains[options[:name]]
        if !options[:id]
          domain = @f_domain_api.index({'search' => "name=\"#{options[:name]}\""}, HEADERS)[0]
          options[:id] = domain[0]['domain']['id']
          @domains[options[:name]] = options[:id]
        end
        result = options[:id]
      else
        options[:name] = @domains.key(options[:id])
        if !options[:name]
          domain = @f_domain_api.show({'id' => options[:id]}, HEADERS)[0]
          options[:name] = domain['domain']['name']
          @domains[options[:name]] = options[:id]
        end
        result = options[:name]
      end

      result
    end

    def foreman_ptable(options={})
      @ptables ||= {}

      if options[:name]
        options[:id] = @ptables[options[:name]]
        if !options[:id]
          ptable = @f_ptable_api.index({'search' => "name=\"#{options[:name]}\""}, HEADERS)[0]
          options[:id] = ptable[0]['ptable']['id']
          @ptables[options[:name]] = options[:id]
        end
        result = options[:id]
      elsif options[:id]
        options[:name] = @ptables.key(options[:id])
        if !options[:name]
          ptable = @f_ptable_api.show({'id' => options[:id]}, HEADERS)[0]
          options[:name] = ptable['ptable']['name']
          @ptables[options[:name]] = options[:id]
        end
        result = options[:name]
      elsif !options[:name] && !options[:id]
        result = ''
      end

      result
    end

    def build_os_name(name, major, minor)
      name += " #{major}" if major && major != ""
      name += ".#{minor}" if minor && minor != ""
      name
    end

    def split_os_name(name)
      (name, major, minor) = name.split(' ').collect {|s| s.split('.')}.flatten
      [name, major || "", minor || ""]
    end
  end
end