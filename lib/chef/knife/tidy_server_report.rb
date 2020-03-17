require 'chef/knife/tidy_base'

class Chef
  class Knife
    class TidyServerReport < Knife

      include Knife::TidyBase

      deps do
        require 'ffi_yajl'
      end

      banner "knife tidy server report (options)"

      option :node_threshold,
        :long => '--node-threshold NUM_DAYS',
        :default => 30,
        :description => 'Maximum number of days since last checkin before node is considered stale (default: 30)'

      option :keep_versions,
        long: "--keep-versions MIN",
        default: 0,
        description: "Keep a minimum of this many versions of each cookbook (default: 0)"

      def run
        ensure_reports_dir!

        ui.warn "Writing to #{tidy.reports_dir} directory"
        delete_existing_reports

        orgs = if config[:org_list]
                 config[:org_list].split(',')
               else
                 all_orgs
               end

        stale_orgs = []
        node_threshold = config[:node_threshold].to_i
        keep_versions  = config[:keep_versions].to_i

        orgs.each do |org|
          ui.info "  Organization: #{org}"
          cb_list = cookbook_list(org)
          version_count = cookbook_count(cb_list).sort_by(&:last).reverse.to_h
          used_cookbooks = {}
          nodes = nodes_list(org)[0]

          used_cookbooks = keep_cookbook_versions(cb_list, keep_versions)

          nodes.each do |node|
            # If the node hasn't checked in.
            unless node["chef_packages"]
              # If the node is under an hour old.
              if (Time.now.to_i - node["ohai_time"].to_i) < 3600
                unconverged_recent_nodes << node["name"]
              end
              next
            end
            chef_version = Gem::Version.new(node["chef_packages"]["chef"]["version"])
            # If the node has checked in within the node_threshold with a client older than 12.3
            if chef_version < Gem::Version.new("12.3") && (Time.now.to_i - node["ohai_time"].to_i) <= node_threshold * 86400
              pre_12_3_nodes << node["name"]
            end
          end

          nodes.select { |node| !node["cookbooks"].nil? }.each do |node|
            node["cookbooks"].each do |name, version_hash|
              version = Gem::Version.new(version_hash["version"]).to_s
              if used_cookbooks[name]
                used_cookbooks[name].push(version) unless used_cookbooks[name].include?(version)
              else
                used_cookbooks[name] = [version]
              end
            end
          end

          Chef::Log.debug("Used cookbook list before checking environments: #{used_cookbooks}")
          pins = environment_constraints(org)
          used_cookbooks = check_environment_pins(used_cookbooks, pins, cb_list)
          Chef::Log.debug("Used cookbook list after checking environments: #{used_cookbooks}")

          stale_nodes = []
          nodes.each do |n|
            if (Time.now.to_i - n['ohai_time'].to_i) >= node_threshold * 86400
              stale_nodes.push(n['name'])
            end
          end

          stale_nodes_hash = {'threshold_days': node_threshold, 'count': stale_nodes.count, 'list': stale_nodes}
          stale_orgs.push(org) if stale_nodes.count == nodes.count

          tidy.write_new_file(unused_cookbooks(used_cookbooks, cb_list), ::File.join(tidy.reports_dir, "#{org}_unused_cookbooks.json"))
          tidy.write_new_file(unused_cookbooks(used_cookbooks, cb_list), ::File.join(tidy.reports_dir, "#{org}_unused_cookbooks.json"))
          tidy.write_new_file(version_count, ::File.join(tidy.reports_dir, "#{org}_cookbook_count.json"))
          tidy.write_new_file(stale_nodes_hash, ::File.join(tidy.reports_dir, "#{org}_stale_nodes.json"))
        end

        completion_message
      end

      def ensure_reports_dir!
        Dir.mkdir(tidy.reports_dir) unless Dir.exist?(tidy.reports_dir)
      end

      def delete_existing_reports
        files = Dir[::File.join(tidy.reports_dir, '*.json')]
        unless files.empty?
          ui.confirm("You have existing reports in #{tidy.reports_dir}. Remove")
          FileUtils.rm(files, :force => true)
        end
      end

      def nodes_list(org)
        Chef::Search::Query.new("#{server.root_url}/organizations/#{org}").search(
          :node, '*:*',
          :filter_result => {
            'name' => ['name'],
            'cookbooks' => ['cookbooks'],
            'ohai_time' => ['ohai_time']
          }
        )
      end

      def cookbook_list(org)
        cb_list = {}
        rest.get("/organizations/#{org}/cookbooks?num_versions=all").each do |name, data|
          data['versions'].each do |version_hash|
            version = Gem::Version.new(version_hash['version']).to_s
            if cb_list[name] && !cb_list[name].include?(version)
              cb_list[name].push(version)
            else
              cb_list[name] = [version]
            end
          end
        end
        cb_list
      end

      def keep_cookbook_versions(cb_list, min)
        retain = {}
        cb_list.each do |name, versions|
          keep = versions.sort { |a, b| Gem::Version.new(a) <=> Gem::Version.new(b) }.last(min)
          retain[name] = keep
        end
        retain
      end

      def cookbook_count(cb_list)
        cb_count_list = {}
        cb_list.each do |name, versions|
          cb_count_list[name] = versions.count
        end
        cb_count_list
      end

      def unused_cookbooks(used_list, cb_list)
        unused_list = {}
        cb_list.each do |name, versions|
          if used_list[name].nil? # Not in the used list at all (Remove all versions)
            unused_list[name] = versions
          elsif used_list[name].sort != versions  # Is in the used cookbook list, but version arrays do not match (Find unused versions)
            unused_list[name] = versions - used_list[name]
          end
        end
        unused_list
      end

      def all_orgs
        rest.get('organizations').keys
      end

      def all_environments(org)
        rest.get("/organizations/#{org}/environments").values
      end

      def environment_constraints(org)
        constraints = {}
        all_environments(org).each do |env|
          e = rest.get(env)
          e['cookbook_versions'].each do |cb, version|
            if constraints[cb]
              constraints[cb].push(version) unless constraints[cb].include?(version)
            else
              constraints[cb] = [version]
            end
          end
        end
        constraints
      end

      def check_cookbook_list(cb_list, cb, version)
        if cb_list[cb]
          cb_list[cb].each do |v|
            if Gem::Dependency.new('', version).match?('', v)
              Chef::Log.debug("Pin of #{cb} can be satisfied by #{v}, adding to used list")
              return [v]
            else
              Chef::Log.debug("Pin of #{cb} version #{version} not satisfied by #{v}")
            end
          end
        else
          Chef::Log.info("Cookbook #{cb} version #{version} is pinned in an environment, but does not exist on the server in this org.")
        end
        return nil
      end

      def check_environment_pins(used_cookbooks, pins, cb_list)
        pins.each do |cb, versions|
          versions.each do |version|
            if used_cookbooks[cb]
              # This pinned cookbook is in the used list, now check for a matching version.
              used_cookbooks[cb].each do |v|
                if Gem::Dependency.new('', version).match?('', v)
                  # This version in used_cookbooks satisfies the pin
                  Chef::Log.debug("Pin of #{cb}: #{version} is satisfied by #{v}")
                  break
                end
              end
              result = check_cookbook_list(cb_list, cb, version)
              used_cookbooks[cb].push(result[0]) if result
            else
              # No cookbook version for that pin, look through the full cookbook list for a match
              Chef::Log.debug("No used cookbook #{cb}, checking the full cookbook list")
              result = check_cookbook_list(cb_list, cb, version)
              used_cookbooks[cb] = result if result
            end
          end
        end
        used_cookbooks
      end
    end
  end
end
