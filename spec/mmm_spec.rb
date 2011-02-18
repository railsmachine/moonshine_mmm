require File.join(File.dirname(__FILE__), 'spec_helper.rb')

describe "A manifest with the Mmm plugin" do

  before do
    @manifest = MmmManifest.new
    @manifest.configure({:mysql => {:mmm => {
      :interface => 'en1',
      :ping      => '10.0.0.1',
      :db1       => '10.0.0.2',
      :db2       => '10.0.0.3',
      :monitor   => '10.0.0.4',
      :writer    => '10.0.0.5',
      :writer    => '10.0.0.6'
    }}})
  end

  it 'should have a convenience method for the ip address' do
    @manifest.mmm_ip_address.should == Facter.send("ipaddress_en1")
  end

  describe 'monitor role' do

    before do
      @manifest.mmm_monitor
    end

    it 'should be executable' do
      @manifest.should be_executable
    end

    it 'should configure the monitor in active mode by default' do
      @manifest.files["/etc/mysql-mmm/mmm_mon.conf"].content.should match /mode\s*active/
    end

    it 'should notify the monitor of changes to common config' do
      @manifest.files['/etc/mysql-mmm/mmm_common.conf'].notify.title.should == @manifest.services['mysql-mmm-monitor'].title
    end

    it 'should setup the mysql-mmm-monitor service' do
      @manifest.services['mysql-mmm-monitor'].enable.should be_true
    end

  end

  describe 'agent role' do

    before do
      @manifest.mmm_agent
    end

    it 'should be executable' do
      @manifest.should be_executable
    end

    it 'should set the bind address' do
      @manifest.files["/etc/mysql/conf.d/bind_address.conf"].content.should match /0\.0\.0\.0/
    end

    it 'should configure the agent with the proper hostname' do
      @manifest.files["/etc/mysql-mmm/mmm_agent.conf"].content.should match /#{Facter.hostname}/
    end

    it 'should notify the agent of changes to common config' do
      @manifest.files['/etc/mysql-mmm/mmm_common.conf'].notify.title.should == @manifest.services['mysql-mmm-agent'].title
    end

    it 'should setup the mysql-mmm-agent service' do
      @manifest.services['mysql-mmm-agent'].enable.should be_true
    end

    it 'should setup a few mysql users' do
      @manifest.execs['mmm_monitor_user'].command.should match /mmm_monitor@#{@manifest.mmm_options[:monitor]}/
      @manifest.execs['mmm_monitor_agent_user'].command.should match /mmm_agent@#{@manifest.mmm_options[:monitor]}/
      @manifest.execs['mmm_agent_user'].command.should match /mmm_agent@#{@manifest.mmm_ip_address}/
    end

  end

end