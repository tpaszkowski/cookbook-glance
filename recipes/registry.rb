#
# Cookbook Name:: glance
# Recipe:: registry
#
# Copyright 2012, Rackspace US, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

class ::Chef::Recipe
  include ::Openstack
  include ::Opscode::OpenSSL::Password
end

platform_options = node["glance"]["platform"]

package "python-keystone" do
  action :install
end

identity_admin_endpoint = endpoint "identity-admin"

db_user = node["glance"]["db"]["username"]
db_pass = db_password "glance"
sql_connection = db_uri("image", db_user, db_pass)

keystone = config_by_role node["glance"]["keystone_service_chef_role"], "keystone"

# Instead of the search to find the keystone service, put this
# into openstack-common as a common attribute?
ksadmin_user = keystone["admin_user"]
ksadmin_tenant_name = keystone["admin_tenant_name"]
ksadmin_pass = user_password ksadmin_user
auth_uri = ::URI.decode identity_admin_endpoint.to_s
service_pass = service_password "glance"
service_tenant_name = node["glance"]["service_tenant_name"]
service_user = node["glance"]["service_user"]
service_role = node["glance"]["service_role"]

registry_endpoint = endpoint "image-registry"

package "curl" do
  action :install
end

platform_options["mysql_python_packages"].each do |pkg|
  package pkg do
    action :install
  end
end

platform_options["glance_packages"].each do |pkg|
  package pkg do
    action :upgrade
  end
end

directory ::File.dirname(node["glance"]["registry"]["auth"]["cache_dir"]) do
  owner node["glance"]["user"]
  group node["glance"]["group"]
  mode 00700
end

service "glance-registry" do
  service_name platform_options["glance_registry_service"]
  supports :status => true, :restart => true

  action :enable
end

# Having to manually version the database because of Ubuntu bug
# https://bugs.launchpad.net/ubuntu/+source/glance/+bug/981111
execute "glance-manage version_control 0" do
  not_if "glance-manage db_version"
  only_if { platform?(%w{ubuntu debian}) }
end

file "/var/lib/glance/glance.sqlite" do
  action :delete
end

# Register Service Tenant
keystone_register "Register Service Tenant" do
  auth_uri auth_uri
  admin_user ksadmin_user
  admin_tenant_name ksadmin_tenant_name
  admin_password ksadmin_pass
  tenant_name node["glance"]["service_tenant_name"]
  tenant_description "Service Tenant"
  tenant_enabled true # Not required as this is the default

  action :create_tenant
end

# Register Service User
keystone_register "Register #{service_user} User" do
  auth_uri auth_uri
  admin_user ksadmin_user
  admin_tenant_name ksadmin_tenant_name
  admin_password ksadmin_pass
  tenant_name node["glance"]["service_tenant_name"]
  user_name service_user
  user_pass service_pass
  user_enabled true # Not required as this is the default

  action :create_user
end

## Grant Admin role to Service User for Service Tenant ##
keystone_register "Grant '#{service_role}' Role to #{service_user} User for #{service_tenant_name} Tenant" do
  auth_uri auth_uri
  admin_user ksadmin_user
  admin_tenant_name ksadmin_tenant_name
  admin_password ksadmin_pass
  tenant_name service_tenant_name
  user_name service_user
  role_name service_role

  action :grant_role
end

directory "/etc/glance" do
  owner node["glance"]["user"]
  group node["glance"]["group"]
  mode  00700
end

if node["glance"]["registry"]["bind_interface"].nil?
  bind_address = registry_endpoint.host
else
  bind_address = node["network"]["ipaddress_#{node["glance"]["registry"]["bind_interface"]}"]
end

template "/etc/glance/glance-registry.conf" do
  source "glance-registry.conf.erb"
  owner  "root"
  group  "root"
  mode   00644
  variables(
    :registry_bind_address => bind_address,
    :registry_port => registry_endpoint.port,
    :sql_connection => sql_connection,
    "identity_endpoint" => identity_admin_endpoint,
    "service_pass" => service_pass
  )

  notifies :restart, "service[glance-registry]", :immediately
end

#sync db after config file is generated
execute "glance-manage db_sync"

template "/etc/glance/glance-registry-paste.ini" do
  source "glance-registry-paste.ini.erb"
  owner  "root"
  group  "root"
  mode   00644

  notifies :restart, "service[glance-registry]", :immediately
end
