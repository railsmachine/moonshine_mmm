# Moonshine MMM

A [Moonshine](http://github.com/railsmachine/moonshine) plugin for installing and managing [mysql_mmm](http://mysql-mmm.org).


## We strongly recommend using [MariaDB Galera Cluster](http://github.com/railsmachine/moonshine_mariadb) instead of mmm.

### Instructions

- <tt>script/plugin install git://github.com/railsmachine/moonshine_mmm.git</tt>
- Configure settings if needed in <tt>config/moonshine.yml</tt>

```
    :mysql
      :mmm:
        :enabled: true
        :monitor:   10.0.4.173   # the ip address of the mmm monitor node
        :db1:       10.0.4.183   # the ip address of db1
        :db2:       10.0.4.184   # the ip address of db2
        :writer:    10.0.4.220   # the ip address of writer VIP
        :reader:    10.0.4.221   # the ip address of reader VIP
        :ping:      10.0.0.1     # an ip address to ping to ensure network is up before doing crazy things
        :interface: eth1         # interface that the mmm_agent will use to connect to mysql (used to setup a mysql user)
```

- If your dbs aren't named db1, and db2, denote which one is which like so:

```
    :mysql
      :mmm:
        :db_map:
          :db1: guinness
          :db2: dales
```

- Invoke the recipe(s) in your Moonshine manifest

```
    recipe :mmm_agent        # on the database hosts
    recipe :mmm_monitor      # on the mmm monitor host
```

### MySQL Bind Address

To use MMM, the bind address on your MySQL instance needs to be set to 0.0.0.0.
To do this, MySQL needs to be restarted. If you've already configured this by
other means, you can set this in your <tt>config/moonshine.yml</tt> and avoid
the restart

```
  :mysql
      :mmm:
        :bind_address_already_configured: true
```

### Security

We *strongly* recommend that you configure a firewall, since mysql mmm
configures MySQL to listen on a public interface. [moonshine_iptables](http://github.com/railsmachine/moonshine_iptables)
is a great help here.

If you use moonshine_iptables, make sure you allow traffic from the monitor
to the db servers:

```
    # mmm connection to mysql
    rules << "-A INPUT -s #{configuration[:mysql][:mmm][:monitor]} -p tcp -m tcp --dport 3306 -j ACCEPT"
    # mmm connection to the agent
    rules << "-A INPUT -s #{configuration[:mysql][:mmm][:monitor]} -p tcp -m tcp --dport 9989 -j ACCEPT"
```

#### Initial Setup

Initially, <tt>mmm_control show</tt> indicates all hosts are in the <tt>AWAITING_RECOVERY</tt>
state:

```
    # mmm_control show
      db1(192.168.0.11) master/AWAITING_RECOVERY. Roles:
      db2(192.168.0.12) master/AWAITING_RECOVERY. Roles:
```

MMM sets 'new' hosts to the <tt>AWAITING_RECOVERY</tt> state:

```
    # tail /var/log/mysql-mmm/mmmd_mon.warn
    ...
    2009/10/28 23:15:28  WARN Detected new host 'db1': Setting its initial state to 'AWAITING_RECOVERY'. Use 'mmm_control set_online db1' to switch it online.
    2009/10/28 23:15:28  WARN Detected new host 'db2': Setting its initial state to 'AWAITING_RECOVERY'. Use 'mmm_control set_online db2' to switch it online.
    2009/10/28 23:15:28  WARN Detected new host 'db3': Setting its initial state to 'AWAITING_RECOVERY'. Use 'mmm_control set_online db3' to switch it online.
    2009/10/28 23:15:28  WARN Detected new host 'db4': Setting its initial state to 'AWAITING_RECOVERY'. Use 'mmm_control set_online db4' to switch it online.
```

You need to manually set the hosts online once, and then you're good:

```
    # mmm_control set_online db1
    OK: State of 'db1' changed to ONLINE. Now you can wait some time and check its new roles!
    # mmm_control set_online db2
    OK: State of 'db2' changed to ONLINE. Now you can wait some time and check its new roles!
```

Now all is well!

```
    # mmm_control show
      db1(192.168.0.11) master/ONLINE. Roles: writer(192.168.0.13)
      db2(192.168.0.12) master/ONLINE. Roles: reader(192.168.0.14)
    # Role writer is assigned to it's preferred host db1.
```

***
Unless otherwise specified, all content copyright &copy; 2014, [Rails Machine, LLC](http://railsmachine.com)
