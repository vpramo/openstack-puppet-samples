#!/bin/bash

apt-get update
export git_protocol=https
apt-get --assume-yes install ruby
apt-get --assume-yes install git
export git_protocol=https
gem install librarian-puppet-simple --no-ri --no-rdoc 
wget -O puppet.deb -t 5 -T 30 http://apt.puppetlabs.com/puppetlabs-release-pc1-xenial.deb
dpkg -i puppet.deb 
apt-get update
apt-get install -y puppet software-properties-common 

