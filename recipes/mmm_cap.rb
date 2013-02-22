set(:mmm_innobackup_cmd) { 'innobackupex-1.5.1' }
set(:mmm_xtra_scratch_dir) { '/tmp/master-xtrabackup' }

set :mmm_servers do
  find_servers(:roles => :db)
end

set :mmm_initial_master do
  find_servers(:roles => :db, :only => {:primary => true}).first
end

set :mmm_initial_slave do
  find_servers(:roles => :db, :except => {:primary => true}).first
end

namespace :mysql do
  namespace :mmm do
    task :setup, :roles => :db do
      run "mkdir -p #{mmm_xtra_scratch_dir}"

      if mysql[:xtrabackup] and mysql[:xtrabackup].is_a?(Hash) and mysql[:xtrabackup][:defaults_file]
        set :mysql_defaults, mysql[:xtrabackup][:defaults_file]
      else
        set :mysql_defaults, '/etc/mysql/my.cnf'
      end

      transaction do
        keys
        snapshot
        scp
        apply_snapshot
        start_slave
        start_slave_from_slave
        status
      end
    end

    task :keys, :roles => :db do
      download "/home/#{user}/.ssh/id_rsa.pub", 'master_db-id_rsa.pub', :hosts => mmm_initial_master
      download "/home/#{user}/.ssh/id_rsa", 'master_db-id_rsa', :hosts => mmm_initial_master
      upload 'master_db-id_rsa', "/home/#{user}/.ssh/id_rsa", :hosts => mmm_initial_slave
      upload 'master_db-id_rsa.pub', "/home/#{user}/.ssh/id_rsa.pub", :hosts => mmm_initial_slave

      run "grep -f /home/#{user}/.ssh/id_rsa.pub /home/#{user}/.ssh/authorized_keys || cat /home/#{user}/.ssh/id_rsa.pub >> /home/#{user}/.ssh/authorized_keys"
    end

    task :snapshot, :roles => :db do
      on_rollback { run "rm -rf #{mmm_xtra_scratch_dir}/#{latest_backup}" }

      # TODO: instead of parsing output to set these vars, find newest dir
      # in mmm_xtra_scratch_dir and read its xtrabackup_binlog_info. That way a separate
      # task can do this so start_slave etc. can be used without a new snapshot
      sudo "#{mmm_innobackup_cmd} --defaults-file=#{mysql_defaults} #{mmm_xtra_scratch_dir}", :hosts => mmm_initial_master do |ch, stream, data|
        logger.info "[#{stream} :: #{ch[:host]}] #{data}"

        if data =~ /Backup created in directory \'(.*)\'/
          set :latest_backup, $1.split('/').last
        end

        if data =~ /MySQL binlog position: filename \'(.*)\', position (\d*)/
          set :mmm_master_binlog_file, $1
          set :mmm_master_binlog_position, $2
        end
      end
      sudo "chown -R #{user}:#{user} #{mmm_xtra_scratch_dir}/#{latest_backup}", :hosts => mmm_initial_master
    end

    desc "[internal] Copy latest innobackupex backup by SCP to slaves."
    task :scp, :roles => :db do
      run "ssh #{mmm_initial_slave.host} -p #{ssh_options[:port] || 22} 'mkdir -p #{mmm_xtra_scratch_dir}'", :hosts => mmm_initial_master do |ch, stream, data|
        # pesky SSH fingerprint prompts
        ch.send_data("yes\n") if data =~ %r{\(yes/no\)}
      end
      run "scp -P #{ssh_options[:port] || 22} -r #{mmm_xtra_scratch_dir}/#{latest_backup} #{mmm_initial_slave}:#{mmm_xtra_scratch_dir}", :hosts => mmm_initial_master
    end

    desc "[internal] Apply initial XtraBackup snapshot"
    task :apply_snapshot, :roles => :db do
      slave = {:hosts => mmm_initial_slave}
      sudo 'service mysql stop || true', slave
      sudo 'rm -rf /var/lib/mysql.old', slave
      sudo 'mv /var/lib/mysql /var/lib/mysql.old', slave
      sudo 'mkdir /var/lib/mysql', slave

      # The whiz-bang part
      sudo "#{mmm_innobackup_cmd} --defaults-file=#{mysql_defaults} --apply-log #{mmm_xtra_scratch_dir}/#{latest_backup}", slave
      sudo "#{mmm_innobackup_cmd} --defaults-file=#{mysql_defaults} --copy-back #{mmm_xtra_scratch_dir}/#{latest_backup}", slave

      sudo 'chown -R mysql:mysql /var/lib/mysql', slave
      sudo 'service mysql start', slave
    end

    desc "[internal] Start slave. Depends on :snapshot task to set binlog params"
    task :start_slave, :roles => :db do
      master = {:hosts => mmm_initial_master}

      # TODO don't hardcode
      sudo "ifconfig eth1", master do |ch, stream, data|
        if data =~ /inet addr:([^\s]+)/
          set :mmm_master_host, $1
        end
      end


      slave = {:hosts => mmm_initial_slave}
      # FIXME: this breaks for case like database.production.yml being copied
      # into place later in the deploy
      db_config = YAML.load_file(File.join(File.dirname(__FILE__), '..', '..', '..', '..', 'config', 'database.yml'))
      rails_env = fetch(:rails_env, 'production').to_s
      master_host_query = <<SQL
CHANGE MASTER TO MASTER_HOST='#{mmm_master_host}',
MASTER_USER='repl',
MASTER_PASSWORD='#{db_config[rails_env]['password']}',
MASTER_LOG_FILE='#{fetch :mmm_master_binlog_file}',
MASTER_LOG_POS=#{fetch :mmm_master_binlog_position};
SQL

      sudo "/usr/bin/mysql -u root -e \"#{master_host_query}\"", slave
      sudo "/usr/bin/mysql -u root -e 'start slave;'", slave
    end

    task :start_slave_from_slave, :roles => :db do
      master = {:hosts => mmm_initial_master}
      slave = {:hosts => mmm_initial_slave}

      sudo "/usr/bin/mysql -u root -e 'show master status \\G;'", slave do |ch, stream, data|
        if data =~ /File: ([^\s]+)/
          set :mmm_slave_binlog_file, $1
          logger.info "Marking slave binlog file #{$1}"
        end
        if data =~ /Position: ([^\s]+)/
          set :mmm_slave_binlog_position, $1.to_i
          logger.info "Marking slave binlog pos #{$1}"
        end
      end

      # TODO don't hardcode
      sudo "ifconfig eth1", slave do |ch, stream, data|
        if data =~ /inet addr:([^\s]+)/
          set :mmm_slave_host, $1
        end
      end

      # FIXME: this breaks for case like database.production.yml being copied
      # into place later in the deploy
      db_config = YAML.load_file(File.join(File.dirname(__FILE__), '..', '..', '..', '..', 'config', 'database.yml'))
      rails_env = fetch(:rails_env, 'production').to_s
      master_host_query = <<SQL
CHANGE MASTER TO MASTER_HOST='#{mmm_slave_host}',
MASTER_USER='repl',
MASTER_PASSWORD='#{db_config[rails_env]['password']}',
MASTER_LOG_FILE='#{fetch :mmm_slave_binlog_file}',
MASTER_LOG_POS=#{fetch :mmm_slave_binlog_position};
SQL

      sudo "/usr/bin/mysql -u root -e 'stop slave;'", master
      sudo "/usr/bin/mysql -u root -e 'reset slave;'", master
      sudo "/usr/bin/mysql -u root -e \"#{master_host_query}\"", master
      sudo "/usr/bin/mysql -u root -e 'start slave;'", master
    end


    desc "Check replication with a 'show slave status' query"
    task :status, :roles => :db do
      sudo "/usr/bin/mysql -u root -e 'show slave status \\G;'"
    end

  end
end
