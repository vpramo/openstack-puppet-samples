##### Main Variables ######

$os_aio1=<IP1>
$os_aio2=<IP2>
$lb_router1=<IP3>

$lb_ip=$lb_router1
$mysql_ip=$os_aio1
$rabbit_ip=$os_aio1



$api_workers = 1


$admin_password = 'Passw0rd'
$demo_password = $admin_password
$admin_token = '4b46b807-ab35-4a67-9f5f-34bbff2dd439'
$metadata_proxy_shared_secret = '39c24deb-0d57-4184-81da-fc8ede37082e'
$region_name = 'RegionOne'

$interface = 'ens3'
$ext_bridge_interface = 'br-ex'

$nova_backends=[$os_aio1,$os_aio2]
$neutron_backends=[$os_aio1,$os_aio2]
$glance_backends=[$os_aio2]
$horizon_backends=[$os_aio1,$os_aio2]
$server_names=["os_aio1","os_aio2"]
$glance_names=["os_aio2"]


##### Generate GW & IP from Interface #####

$gateway = generate('/bin/sh',
'-c', '/sbin/ip route show | /bin/grep default | /usr/bin/awk \'{print $3}\'')

$ext_bridge_interface_repl = regsubst($ext_bridge_interface, '-', '_')
$ext_bridge_interface_ip = inline_template(
"<%= scope.lookupvar('::ipaddress_${ext_bridge_interface_repl}') -%>")

if $ext_bridge_interface_ip {
  $local_ip = $ext_bridge_interface_ip
  $local_ip_netmask = inline_template(
"<%= scope.lookupvar('::netmask_${ext_bridge_interface_repl}') -%>")
} else {
  $local_ip = inline_template(
"<%= scope.lookupvar('::ipaddress_${interface}') -%>")
  $local_ip_netmask = inline_template(
"<%= scope.lookupvar('::netmask_${interface}') -%>")
}

################################## ENable APT for Newton ###################


if !$local_ip {
  fail('$local_ip variable must be set')
}

notify { "Local IP: ${local_ip}":}
->
notify { "Netmask: ${local_ip_netmask}":}
->
notify { "Gateway: ${gateway}":}

package { 'ubuntu-cloud-keyring':
  ensure => latest,
}

class { 'apt': }
apt::source { 'ubuntu-cloud':
  location          =>  'http://ubuntu-cloud.archive.canonical.com/ubuntu',
  repos             =>  'main',
  release           =>  'xenial-updates/newton',
  include           =>  {'src' => false,},
}
->
exec { 'apt-update':
    command => '/usr/bin/apt-get update'
    }
#########################################################################


################################# MYSQL ################

class { 'mysql::server':
  root_password    => $admin_password,
  override_options => { 'mysqld' => { 'bind_address'           => '0.0.0.0',
                                      # Not necessary starting from MySQL 5.5
                                      'default_storage_engine' => 'InnoDB',
                                      'max_connections'        => 1024,
                                      'open_files_limit'       => -1 } },
  restart          => true,
}


########################################################


############################## RabbitMQ ###########################


class { '::rabbitmq':
  service_ensure    => 'running',
  port              => '5672',
  delete_guest_user => true,
}

rabbitmq_user { 'openstack':
  admin    => false,
  password => $admin_password,
  tags     => ['openstack'],
}

rabbitmq_vhost { '/':
  ensure => present,
}

rabbitmq_user_permissions { 'openstack@/':
  configure_permission => '.*',
  read_permission      => '.*',
  write_permission     => '.*',
}

######################################################################

########################### Glance DB ###############################

class { 'glance::db::mysql':
  password      => $admin_password,
  allowed_hosts => '%',
 
}
############################ Keystone ###############################

class { 'keystone::db::mysql':
  password      => $admin_password,
  allowed_hosts => '%',

}

class { 'keystone':
  verbose               => True,
  package_ensure        => latest,
  client_package_ensure => latest,
  service_name => 'httpd',
  catalog_type          => 'sql',
  admin_token           => $admin_token,
  database_connection   =>
"mysql://keystone:${admin_password}@${mysql_ip}/keystone",
}

# Installs the service user endpoint.
class { 'keystone::endpoint':
  public_url   => "http://${lb_ip}:5000",
  admin_url    => "http://${lb_ip}:35357",
  internal_url => "http://${lb_ip}:5000",
  region       => $region_name,
}

class { '::keystone::wsgi::apache':
  ssl=> false
}

keystone_tenant { 'admin':
  ensure  => present,
  enabled => True,
}

keystone_tenant { 'services':
  ensure  => present,
  enabled => True,
}

keystone_tenant { 'demo':
  ensure => present,
}

keystone_user { 'admin':
  ensure   => present,
  enabled  => True,
  password => $admin_password,
  email    => 'admin@openstack',
}

keystone_user { 'demo':
  ensure   => present,
  enabled  => True,
  password => $demo_password,
  email    => 'demo@openstack',
}

keystone_role { 'admin':
  ensure => present,
}

keystone_role { 'demo':
  ensure => present,
}

keystone_user_role { 'admin@admin':
  ensure => present,
  roles  => ['admin'],
}

keystone_user_role { 'admin@services':
  ensure => present,
  roles  => ['admin'],
}

keystone_user_role { 'demo@demo':
  ensure => present,
  roles  => ['demo'],
}


######################################################################

########################Nova###############################

keystone_service { 'nova':
  ensure      => present,
  type        => 'compute',
  description => 'Openstack Compute Service',
}

keystone_endpoint { "${region_name}/nova":
  ensure       => present,
  public_url   => "http://${lb_ip}:8774/v2/%(tenant_id)s",
  admin_url    => "http://${lb_ip}:8774/v2/%(tenant_id)s",
  internal_url => "http://${lb_ip}:8774/v2/%(tenant_id)s",
}

keystone_user { 'nova':
  ensure   => present,
  enabled  => True,
  password => $admin_password,
  email    => 'nova@openstack',
}

keystone_user_role { 'nova@services':
  ensure => present,
  roles  => ['admin'],
}

class { 'nova':
  database_connection =>
"mysql://nova:${admin_password}@${mysql_ip}/nova?charset=utf8",
  api_database_connection => 
  "mysql://nova_api:${admin_password}@${mysql_ip}/nova_api?charset=utf8",
  rabbit_userid       => 'openstack',
  rabbit_password     => $admin_password,
  image_service       => 'nova.image.glance.GlanceImageService',
  glance_api_servers  => "http://${lb_ip}:9292",
  verbose             => true,
  rabbit_host         => $rabbit_ip,
}

class { 'nova::db::mysql':
  password      => $admin_password,
  allowed_hosts => '%',
  
}

class { 'nova::db::mysql_api':
  password      => $admin_password,
  allowed_hosts => '%',
 
}

class { 'nova::api':
  enabled                              => true,
  auth_uri                             => "http://${lb_ip}:5000/v2.0",
  identity_uri                         => "http://${lb_ip}:35357",
  admin_user                           => 'nova',
  admin_password                       => $admin_password,
  admin_tenant_name                    => 'services',
  neutron_metadata_proxy_shared_secret => $metadata_proxy_shared_secret,
  osapi_compute_workers                => $api_workers,
  ec2_workers                          => $api_workers,
  metadata_workers                     => $api_workers,
  #ratelimits                          =>
  #'(POST, "*", .*, 10, MINUTE);\
  #(POST, "*/servers", ^/servers, 50, DAY);\
  #(PUT, "*", .*, 10, MINUTE)',
  validate                             => true,
}

class { 'nova::network::neutron':
  neutron_admin_password  => $admin_password,
}

class { 'nova::scheduler':
  enabled => true,
}

class { 'nova::conductor':
  enabled => true,
  workers => $api_workers,
}

class { 'nova::consoleauth':
  enabled => true,
}

class { 'nova::cert':
  enabled => true,
}


class { 'nova::compute':
  enabled           => true,
  vnc_enabled       => true,
  vncproxy_host     => $lb_ip,
  vncproxy_protocol => 'http',
  vncproxy_port     => '6080',
}

class { 'nova::vncproxy':
  enabled           => true,
  host              => '0.0.0.0',
  port              => '6080',
  vncproxy_protocol => 'http',
}

class { 'nova::compute::libvirt':
  migration_support => true,
  # Narrow down listening if not needed for troubleshooting
  vncserver_listen  => '0.0.0.0',
  libvirt_virt_type => 'kvm',
}


######################################################################

########################Neutron###############################

package{'neutron-lbaasv2-agent':
}

keystone_service { 'neutron':
  ensure      => present,
  type        => 'network',
  description => 'Openstack Networking Service',
}

keystone_endpoint { "${region_name}/neutron":
  ensure       => present,
  public_url   => "http://${lb_ip}:9696",
  admin_url    => "http://${lb_ip}:9696",
  internal_url => "http://${lb_ip}:9696",
}

keystone_user { 'neutron':
  ensure   => present,
  enabled  => True,
  password => $admin_password,
  email    => 'neutron@openstack',
}

keystone_user_role { 'neutron@services':
  ensure => present,
  roles  => ['admin'],
}

class { '::neutron':
  enabled               => true,
  bind_host             => '0.0.0.0',
  rabbit_host           => $rabbit_ip,
  rabbit_user           => 'openstack',
  rabbit_password       => $admin_password,
  verbose               => true,
  debug                 => false,
  core_plugin           => 'ml2',
  service_plugins       => ['router', 'metering','neutron_lbaas.services.loadbalancer.plugin.LoadBalancerPluginv2'],
  allow_overlapping_ips => true,
}

class { 'neutron::server':
  username          => 'neutron',
  password       => $admin_password,
  project_name         => 'services',
  auth_uri            => "http://${lb_ip}:5000/v2.0",
  database_connection =>
"mysql://neutron:${admin_password}@${mysql_ip}/neutron?charset=utf8",
  sync_db             => true,
  api_workers         => $api_workers,
  rpc_workers         => $api_workers,
  service_providers => [
       'LOADBALANCER:Haproxy:neutron_lbaas.services.loadbalancer.drivers.haproxy.plugin_driver.HaproxyOnHostPluginDriver',

    ]
}

class { 'neutron::db::mysql':
  password      => $admin_password,
  allowed_hosts => '%',
 
}

class { '::neutron::server::notifications':
  password    => $admin_password,
}

class { '::neutron::agents::ml2::ovs':
  local_ip         => $local_ip,
  enable_tunneling => true,
  tunnel_types     => ['vxlan'],
 
}



vs_bridge { 'br-int':
  ensure => present,
}

vs_bridge { 'br-tun':
  ensure => present,
}

class { '::neutron::plugins::ml2':
  type_drivers         => ['flat', 'vxlan'],
  tenant_network_types => [ 'vxlan'],
  vxlan_group          => '239.1.1.1',
  mechanism_drivers    => ['openvswitch'],
  vni_ranges           => ['1001:2000'], #VXLAN
  tunnel_id_ranges     => ['1001:2000'], #GRE

}

########################################################################

########################Horizon Dashboard###############################

class { 'memcached':
  listen_ip => '127.0.0.1',
  tcp_port  => '11211',
  udp_port  => '11211',
}
->
class { '::horizon':
    cache_server_ip         => '127.0.0.1',
    cache_server_port       => '11211',
    secret_key              => 'Chang3M3',
    keystone_url            => "http://${lb_ip}:5000/v3",
 
    allowed_hosts           => '*'
  }
  
###########################################################################

########################Keystone Source ###############################



file { '/root/keystonerc_admin':
  ensure  => present,
  content =>
"export OS_AUTH_URL=http://${lb_ip}:35357/v2.0
export OS_USERNAME=admin
export OS_PASSWORD=${admin_password}
export OS_TENANT_NAME=admin
export OS_VOLUME_API_VERSION=2
",
}

file { '/root/keystonerc_demo':
  ensure  => present,
  content =>
"export OS_AUTH_URL=http://${lb_ip}:35357/v2.0
export OS_USERNAME=demo
export OS_PASSWORD=${demo_password}
export OS_TENANT_NAME=demo
export OS_VOLUME_API_VERSION=2
",
}

##########################################################################


