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
$server_names=["test-2","test-3"]
$glance_names=["test-3"]

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

#########################################################################


################################## HAPROXY ###################

include ::haproxy

##################################Nova API HAPROXY #############################

haproxy::listen { 'nova-api':
    collect_exported => false,
    ipaddress        => $::ipaddress,
    ports            => '8774',
  }
  
haproxy::balancermember { 'nova-api':
  listening_service => 'nova-api',
  ports             => '8774',
  server_names      => $server_names,
  ipaddresses       => $nova_backends,
  options           => 'check',
}


haproxy::listen { 'nova-metadata':
    collect_exported => false,
    ipaddress        => $::ipaddress,
    ports            => '8775',
  }


 
haproxy::balancermember { 'nova-api':
  listening_service => 'nova-api',
  ports             => '8775',
  server_names      => $server_names,
  ipaddresses       => $nova_backends,
  options           => 'check',
  
}



haproxy::listen { 'nova-vnc':
    collect_exported => false,
    ipaddress        => $::ipaddress,
    ports            => '6080',
  }


 
haproxy::balancermember { 'nova-vnc':
  listening_service => 'nova-api',
  ports             => '6080',
  server_names      => $server_names,
  ipaddresses       => $nova_backends,
  options           => 'check',
}


#########################################################################


##################################Neutron API HAPROXY #############################


haproxy::listen { 'neutron-server':
    collect_exported => false,
    ipaddress        => $::ipaddress,
    ports            => '9696',
  }


 
haproxy::balancermember { 'neutron-server':
  listening_service => 'neutron-server',
  ports             => '9696',
  server_names      => $server_names,
  ipaddresses       => $neutron_backends,
  options           => 'check',
}

#########################################################################


##################################Glance API HAPROXY #############################


haproxy::listen { 'glance-api':
    collect_exported => false,
    ipaddress        => $::ipaddress,
    ports            => '9292',
  }


 
haproxy::balancermember { 'glance-api':
  listening_service => 'glance-api',
  ports             => '9292',
  server_names      => $glance_names,
  ipaddresses       => $glance_backends,
  options           => 'check',
}

#########################################################################


##################################Horizon API HAPROXY #############################


haproxy::listen { 'gorizon-api':
    collect_exported => false,
    ipaddress        => $::ipaddress,
    ports            => '80',
  }


 
haproxy::balancermember { 'horizon-api':
  listening_service => 'horizon-api',
  ports             => '80',
  server_names      => $server_names,
  ipaddresses       => $horizon_backends,
  options           => 'check',
}

#########################################################################


############################### Neutron Support Services ################################


class { '::neutron':
  enabled               => true,
  bind_host             => '0.0.0.0',
  rabbit_host           => $rabbit_ip,
  rabbit_user           => 'openstack',
  rabbit_password       => $admin_password,
  verbose               => true,
  debug                 => false,
  core_plugin           => 'ml2',
  service_plugins       => ['router', 'metering'],
  allow_overlapping_ips => true,
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

vs_bridge {'br-ex':
  ensure => present,
}

class { '::neutron::agents::l3':
  external_network_bridge  => 'br-ex',
}

class { '::neutron::agents::metadata':
  enabled       => true,
  shared_secret => $metadata_proxy_shared_secret,
  metadata_ip   => $lb_ip,
}

class { '::neutron::agents::dhcp':
  enabled                => true,
  enable_isolated_metadata => true,
  enable_force_metadata    => true,
  enable_metadata_network  => true,
}

class { '::neutron::agents::lbaas':
  enabled => true,
}


class { '::neutron::agents::metering':
  enabled => true,
}

class { '::neutron::plugins::ml2':
  type_drivers         => ['flat', 'vxlan'],
  tenant_network_types => ['vxlan'],
  vxlan_group          => '239.1.1.1',
  mechanism_drivers    => ['openvswitch'],
  vni_ranges           => ['1001:2000'], #VXLAN
  tunnel_id_ranges     => ['1001:2000'], #GRE

}


