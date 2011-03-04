module Moonshine
  module Mmm

      def mmm_options
        @options ||= HashWithIndifferentAccess.new({
          :enabled    => true,
          :interface  => 'eth1'
        }).merge(configuration[:mysql][:mmm])
        @options
      end

      def running_or_stopped
        mmm_options[:enabled] ? :running : :stopped
      end

      def mmm_ip_address
        Facter.send("ipaddress_#{mmm_options[:interface]}")
      end

      def mmm_common()
        %w(wget liblog-log4perl-perl libmailtools-perl liblog-dispatch-perl liblog-dispatch-perl libclass-singleton-perl iproute libnet-arp-perl libproc-daemon-perl libalgorithm-diff-perl libdbi-perl libdbd-mysql-perl).each do |p|
          package p, :ensure => :installed, :before => package('mysql-mmm-common')
        end
        user 'mmmd', :shell => '/sbin/nologin', :ensure => :present
        package 'mysql-mmm-common', :ensure => :installed, :provider => :dpkg, :source => "/usr/local/src/mysql-mmm-common_2.2.1-1_all.deb", :require => exec("/usr/local/src/mysql-mmm-common_2.2.1-1_all.deb")
        file '/usr/local/src', :ensure => :directory

        %w(agent common monitor tools).each do |p|
          exec "download mysql-mmm-#{p}",
            :alias   => "/usr/local/src/mysql-mmm-#{p}_2.2.1-1_all.deb",
            :creates => "/usr/local/src/mysql-mmm-#{p}_2.2.1-1_all.deb",
            :command => "wget -O /usr/local/src/mysql-mmm-#{p}_2.2.1-1_all.deb http://mysql-mmm.org/_media/:mmm2:mysql-mmm-#{p}_2.2.1-1_all.deb",
            :cwd     => "/usr/local/src",
            :require => package("wget")
        end
      end

      def mmm_monitor
        mmm_common
        package 'mysql-mmm-monitor', :ensure => :installed, :provider => :dpkg, :source => "/usr/local/src/mysql-mmm-monitor_2.2.1-1_all.deb", :require => [exec("/usr/local/src/mysql-mmm-monitor_2.2.1-1_all.deb"),  package('mysql-mmm-common')]
        file "/etc/default/mysql-mmm-monitor", :ensure => :present, :content => "ENABLED=#{mmm_options[:enabled] ? 1 : 0}"
        service 'mysql-mmm-monitor',
          :ensure   => running_or_stopped,
          :enable   => true,
          :require  => [package('mysql-mmm-monitor'), file("/etc/default/mysql-mmm-monitor")]

        file '/etc/mysql-mmm/mmm_mon.conf',
          :ensure => :present,
          :notify => service('mysql-mmm-monitor'),
          :require => package('mysql-mmm-monitor'),
          :content => template(File.join(File.dirname(__FILE__), '..', '..', 'templates', 'mmm_mon.conf.erb'), binding),
          :owner   => 'root',
          :mode    => '640'
        file '/etc/mysql-mmm/mmm_common.conf',
          :ensure => :present,
          :notify => service('mysql-mmm-monitor'),
          :require => package('mysql-mmm-monitor'),
          :content => template(File.join(File.dirname(__FILE__), '..', '..', 'templates', 'mmm_common.conf.erb'), binding),
          :owner   => 'root',
          :mode    => '640'
      end

      def mmm_agent
        mmm_common
        %w(tools agent).each do |p|
          package "mysql-mmm-#{p}", :ensure => :installed, :provider => :dpkg, :source => "/usr/local/src/mysql-mmm-#{p}_2.2.1-1_all.deb", :require => [exec("/usr/local/src/mysql-mmm-#{p}_2.2.1-1_all.deb"),  package('mysql-mmm-common')]
        end
        file "/etc/default/mysql-mmm-agent", :ensure => :present, :content => "ENABLED=1" if mmm_options[:enabled]
        mmm_monitor_user = <<EOF
GRANT REPLICATION CLIENT
ON *.* 
TO mmm_monitor@#{mmm_options[:monitor]}
IDENTIFIED BY \\"#{database_environment[:password]}\\";
FLUSH PRIVILEGES;
EOF
        exec "mmm_monitor_user",
          :command => mysql_query(mmm_monitor_user),
          :unless  => "mysql -u root -e ' select User from user where Host = \"#{mmm_options[:monitor]}\"' mysql | grep mmm_monitor",
          :require => exec('mysql_database')
        mmm_monitor_agent_user = <<EOF
GRANT REPLICATION CLIENT
ON *.* 
TO mmm_agent@#{mmm_options[:monitor]}
IDENTIFIED BY \\"#{database_environment[:password]}\\";
FLUSH PRIVILEGES;
EOF
        exec "mmm_monitor_agent_user",
          :command => mysql_query(mmm_monitor_agent_user),
          :unless  => "mysql -u root -e ' select User from user where Host = \"#{mmm_options[:monitor]}\"' mysql | grep mmm_agent",
          :require => exec('mysql_database')
        mmm_agent_user = <<EOF
GRANT SUPER, REPLICATION CLIENT, PROCESS
ON *.*
TO mmm_agent@#{mmm_ip_address}
IDENTIFIED BY \\"#{database_environment[:password]}\\";
FLUSH PRIVILEGES;
EOF
        exec "mmm_agent_user",
          :command => mysql_query(mmm_agent_user),
          :unless  => "mysql -u root -e ' select User from user where Host = \"#{mmm_ip_address}\"' mysql | grep mmm_agent",
          :require => exec('mysql_database')

        service 'mysql-mmm-agent',
          :ensure  => running_or_stopped,
          :enable  => true,
          :require => [package('mysql-mmm-agent'),file("/etc/default/mysql-mmm-monitor")]

        file '/etc/mysql-mmm/mmm_common.conf',
          :ensure => :present,
          :notify => service('mysql-mmm-agent'),
          :require => package('mysql-mmm-agent'),
          :content => template(File.join(File.dirname(__FILE__), '..', '..', 'templates', 'mmm_common.conf.erb'), binding),
          :owner   => 'root',
          :mode    => '640'
        file '/etc/mysql-mmm/mmm_agent.conf',
          :ensure => :present,
          :notify => service('mysql-mmm-agent'),
          :require => package('mysql-mmm-agent'),
          :content => template(File.join(File.dirname(__FILE__), '..', '..', 'templates', 'mmm_agent.conf.erb'), binding),
          :owner   => 'root',
          :mode    => '640'

        unless mmm_options[:bind_address_already_configured]
          file '/etc/mysql/conf.d/bind_address.cnf',
            :ensure  => :present,
            :notify  => service('mysql'),
            :content => "bind-address = 0.0.0.0\n",
            :owner   => 'root',
            :mode    => '640'
        end
      end

  end
end