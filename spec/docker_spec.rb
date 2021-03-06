require 'yaml'
require_relative '../lib/dockerhandler'
require 'logger'

log = Logger.new(STDOUT)

class MockPassStore

  def initialize()
  end

  ## rescue GPGME::Error::DecryptFailed upstream for failed passwords
  def get_or_generate_password(folder, name)
    return "passfor:#{folder}:#{name}"
  end

end

RSpec.describe DockerHandler do
  prefix = 'foo2'
  prefix2 = 'bar3'
  config = <<-CONFIG
  provisioner:
    state_file: spec/test-state.yml
  servers:
    web1:
      ipv6:
        docker:
          suffix_bridge: 1:0:0/96
          suffix_net: 2:0:0/96
          static_web: 2:0:a
  security:
    pgp_id: ABCDEFG
  docker:
    web1:
      prefix: #{prefix}
      jobs:
        runner:
          env:
            type: task
      applications:
        mail:
          env:
            domains:
              - mail.penguindreams.org
        content-engine:
          db:
            - mysql
        image-poster:
          cmd: some_command -a -f -t
          db:
            - postgres
        single-db-app:
          db:
            - postgres
        shared-db-app1:
          db:
            - postgres:shared
        shared-db-app2:
          db:
            - postgres:shared
        shared:
          db:
            - postgres
        cron:
          env:
            run_container: +runner
        certbot:
          env:
            test: false
            domains: all
        nginx-static:
          env:
            domains:
              - dyject.com/80
              - penguindreams.org/9000
              - rearviewmirror.cc
        haproxy:
          ipv6_web: true
          env:
            domains: all
            certbot_container: $certbot
          ports:
            - 80
            - 443
          volumes:
            - letsencrypt:/etc/letsencrypt:rw
            - haproxycfg:/etc/haproxy:rw
            - /var/run/docker.sock:/var/run/docker.sock
        con:
          env:
            location: Melbourne
    web2:
      prefix: #{prefix2}
      jobs:
        runner:
          env:
            type: batch
      applications:
        con:
          env:
            location: Wellington
        nginx-static:
          env:
            domains:
              - khanism.org
        mastodon:
          env:
            domains:
              - hitchhiker.social
              - streaming.hitchhiker.social/3000
          db:
            - mysql
            - postgres:special
        content-engine:
          db:
            - postgres
  CONFIG
  cfg_yaml = YAML.load(config)
  config_web1 = DockerHandler.new(cfg_yaml, log, 'web1:test', MockPassStore.new)
  config_web2 = DockerHandler.new(cfg_yaml, log, 'web2:test', MockPassStore.new)

  describe "domain mapping" do
    it "returns a list of each container and its domains (web1)" do
      domains = config_web1.all_domains
      expect(domains).to contain_exactly(['nginx-static', ['dyject.com/80',
        'penguindreams.org/9000', 'rearviewmirror.cc']], ['mail',['mail.penguindreams.org']])
    end
    it "returns a list of each container and its domains (web2)" do
      domains = config_web2.all_domains
      expect(domains).to contain_exactly(['nginx-static', ['khanism.org']],
        ['mastodon',['hitchhiker.social', 'streaming.hitchhiker.social/3000']])
    end
  end

  describe "state loading" do
    it "loads ipv6 addresses for web containers" do
      expect(config_web1.state['servers']['web1']['ipv6']['static_web']).to eq('a:b:c:d::2:0:a')
    end
    it "no settings for web2" do
      expect(config_web2.state['servers']['web2']).to be_nil
    end
    it "static ipv6 address should match subnet and suffix" do
      expect(config_web1.state['servers']['web1']['ipv6']['static_web']).to eq(
         config_web1.state['servers']['web1']['ipv6']['subnet'] +
         cfg_yaml['servers']['web1']['ipv6']['docker']['static_web']
      )
    end
  end

  describe "database configuration" do
    it "should load all database sections (web1)" do
      expect(config_web1.db_mapping.size).to eq(6)
    end
    it "should load all database sections (web2)" do
      expect(config_web2.db_mapping.size).to eq(3)
    end
    it "should use container name as a database name if none specified (web1)" do
      ce = config_web1.db_mapping.find { |i| i[:container] == 'content-engine' }
      expect(ce).to eq({:container=>"content-engine", :db=>"mysql", :password=>"passfor:database/mysql:content-engine"})
      ip = config_web1.db_mapping.find { |i| i[:container] == 'image-poster' }
      expect(ip).to eq({:container=>"image-poster", :db=>"postgres", :password=>"passfor:database/postgres:image-poster"})
      sd = config_web1.db_mapping.find { |i| i[:container] == 'single-db-app' }
      expect(sd).to eq({:container=>"single-db-app", :db=>"postgres", :password=>"passfor:database/postgres:single-db-app"})
    end
    it "should allow of a specific database name (web1)" do
      expect(config_web1.db_mapping.find { |i| i[:container] == 'shared-db-app1' }).to be_nil
      expect(config_web1.db_mapping.find { |i| i[:container] == 'shared-db-app2' }).to be_nil
      sa = config_web1.db_mapping.find { |i| i[:container] == 'shared' }
      expect(sa).to eq({:container=>"shared", :db=>"postgres", :password=>"passfor:database/postgres:shared"})
    end
    it "should allow a container with an unspecified shared name (web1)" do
      sh = config_web1.db_mapping.find { |i| i[:container] == 'shared' }
      expect(sh).to eq({:container=>"shared", :db=>"postgres", :password=>"passfor:database/postgres:shared"})
    end
    it "should allow two databases for a container (web2)" do
      w2 = config_web2.db_mapping.find { |i| i[:container] == 'mastodon' }
      expect(w2).to eq({:container=>'mastodon', :db=>'mysql', :password=>'passfor:database/mysql:mastodon'})
    end
    it "should not allow containers to bleed from web1 to web2" do
      expect(config_web2.db_mapping.find { |i| i[:container] == 'image-poster' }).to be_nil
    end
  end

  describe "container configuration" do
    it "shouldn't use links" do
      r = config_web1.config_to_containers('apps', 'nginx-static')
      expect(r["#{prefix}-app-nginx-static"]['container_args']['HostConfig']).not_to have_key('Links')
    end

    it "connect to network" do
      r = config_web1.config_to_containers('apps', 'haproxy')
      host_config = r["#{prefix}-app-haproxy"]['container_args']['NetworkingConfig']['EndpointsConfig']
      expect(host_config).to have_key("#{prefix}-network")
    end

    it "mapping with variables in env referencing other app containers" do
      r = config_web1.config_to_containers('apps', 'haproxy')
      expect(r["#{prefix}-app-haproxy"]['container_args']['Env']).to include("CERTBOT_CONTAINER=#{prefix}-app-certbot")
    end

    it "mapping with variables in env referencing other job containers" do
      r = config_web1.config_to_containers('apps', 'cron')
      expect(r["#{prefix}-app-cron"]['container_args']['Env']).to include("RUN_CONTAINER=#{prefix}-job-runner")
    end

    it "specifies a custom command if present" do
      r = config_web1.config_to_containers('apps', 'image-poster')
      expect(1 == 2)
      expect(r["#{prefix}-app-image-poster"]['container_args']['Cmd']).to  eq(['some_command', '-a', '-f', '-t'])
    end

    it "does not specify a custom command if not present" do
      r = config_web1.config_to_containers('apps', 'cron')
      expect(r["#{prefix}-app-cron"]['container_args']['Cmd']).to be_nil
    end

    it "job containers should start with job prefix (web1)" do
      r = config_web1.config_to_containers('jobs', 'runner')
      expect(r["#{prefix}-job-runner"]['container_args']['Env']).to include("TYPE=task")
    end

    it "job containers should start with job prefix (web2)" do
      r = config_web2.config_to_containers('jobs', 'runner')
      expect(r["#{prefix2}-job-runner"]['container_args']['Env']).to include("TYPE=batch")
    end

    it "mapping with exposed ports" do
      r = config_web1.config_to_containers('apps', 'haproxy')
      expect(r["#{prefix}-app-haproxy"]['container_args']['ExposedPorts']).to eq(
        {"80/tcp"=>{}, "443/tcp"=>{}}
      )

      expect(r["#{prefix}-app-haproxy"]['container_args']['HostConfig']['PortBindings']).to eq(
        {"80/tcp"=>[{"HostPort"=>"80"}], "443/tcp"=>[{"HostPort"=>"443"}]}
      )
    end

    it "mapping with volumes" do
      r = config_web1.config_to_containers('apps', 'haproxy')
      expect(r["#{prefix}-app-haproxy"]['container_args']['HostConfig']['Binds']).to contain_exactly(
        "letsencrypt:/etc/letsencrypt:rw",
        "haproxycfg:/etc/haproxy:rw",
        "/var/run/docker.sock:/var/run/docker.sock"
      )
    end

    it "mapping all domains" do
      r = config_web1.config_to_containers('apps', 'haproxy')
      expect(r["#{prefix}-app-haproxy"]['container_args']['Env']).to include(
        "DOMAINS=#{prefix}-app-mail:mail.penguindreams.org #{prefix}-app-nginx-static:dyject.com/80,penguindreams.org/9000,rearviewmirror.cc"
      )
    end

    it "app configuration local to web1" do
      r = config_web1.config_to_containers('apps', 'con')
      expect(r["#{prefix}-app-con"]['container_args']['Env']).to contain_exactly(
        "LOCATION=Melbourne"
      )
    end

    it "app configuration local to web2" do
      r = config_web2.config_to_containers('apps', 'con')
      expect(r["#{prefix2}-app-con"]['container_args']['Env']).to contain_exactly(
        "LOCATION=Wellington"
      )
    end

    it "web container with static IPv6 address" do
      r = config_web1.config_to_containers('apps', 'haproxy')
      expect(r["#{prefix}-app-haproxy"]['container_args']['NetworkingConfig']['EndpointsConfig']["#{prefix}-network"]['IPAMConfig']['IPv6Address']).to eq('a:b:c:d::2:0:a')
    end

    it "container without a web IPv6 address" do
      r = config_web1.config_to_containers('apps', 'nginx-static')
      expect(r["#{prefix}-app-nginx-static"]).to_not have_key('NetworkingConfig')
    end
  end

end
