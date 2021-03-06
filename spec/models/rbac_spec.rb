require "spec_helper"

describe Rbac do
  before { User.stub(:server_timezone => "UTC") }
  let(:default_tenant) { Tenant.seed }

  let(:owner_tenant) { FactoryGirl.create(:tenant) }
  let(:owner_group)  { FactoryGirl.create(:miq_group, :tenant => owner_tenant) }
  let(:owner_user)   { FactoryGirl.create(:user, :userid => 'foo', :miq_groups => [owner_group]) }
  let(:owned_vm)     { FactoryGirl.create(:vm_vmware, :tenant => owner_tenant) }

  let(:other_tenant) { FactoryGirl.create(:tenant) }
  let(:other_group)  { FactoryGirl.create(:miq_group, :tenant => other_tenant) }
  let(:other_user)   { FactoryGirl.create(:user, :userid => 'bar', :miq_groups => [other_group]) }

  let(:child_tenant) { FactoryGirl.create(:tenant, :divisible => false, :parent => owner_tenant) }
  let(:child_group)  { FactoryGirl.create(:miq_group, :tenant => child_tenant) }
  let(:owned_openstack_vm) { FactoryGirl.create(:vm_openstack, :tenant => child_tenant, :miq_group => child_group) }

  context "tenant scoping" do
    klass_factory_names = [
      "ExtManagementSystem", :ems_vmware,
      "MiqAeDomain", :miq_ae_domain,
      # "MiqRequest", :miq_request,  # MiqRequest is an abstract class that can't be instantiated currently
      "MiqRequestTask", :miq_request_task,
      "Provider", :provider,
      "Service", :service,
      "ServiceTemplate", :service_template,
      "ServiceTemplateCatalog", :service_template_catalog,
      "Vm", :vm_vmware
    ]

    klass_factory_names.each_slice(2) do |klass, factory_name|
      context "#{klass} basic filtering" do
        let(:owned_resource) { FactoryGirl.create(factory_name, :tenant => owner_tenant) }

        before { owned_resource }

        it ".search with :userid, finds user's tenant #{klass}" do
          results = Rbac.search(:class => klass, :results_format => :objects, :userid => owner_user.userid).first
          expect(results).to eq [owned_resource]
        end

        it ".search with :userid filters out other tenants" do
          results = Rbac.search(:class => klass, :results_format => :objects, :userid => other_user.userid).first
          expect(results).to eq []
        end
      end
    end

    context "Advanced filtering" do
      before { owned_vm }
      it ".search with User.with_user finds user's tenant object" do
        User.with_user(owner_user) do
          results = Rbac.search(:class => "Vm", :results_format => :objects).first
          expect(results).to eq [owned_vm]
        end
      end

      it ".search with User.with_user filters out other tenants" do
        User.with_user(other_user) do
          results = Rbac.search(:class => "Vm", :results_format => :objects).first
          expect(results).to eq []
        end
      end

      it ".search with :miq_group_id, finds user's tenant object" do
        results = Rbac.search(:class => "Vm", :results_format => :objects, :miq_group_id => owner_group.id).first
        expect(results).to eq [owned_vm]
      end

      it ".search with :miq_group_id filters out other tenants" do
        results = Rbac.search(:class => "Vm", :results_format => :objects, :miq_group_id => other_group.id).first
        expect(results).to eq []
      end

      it ".search with User.with_user leaving tenant" do
        User.with_user(owner_user) do
          owner_user.miq_groups = [other_group]
          owner_user.save
          results = Rbac.search(:class => "Vm", :results_format => :objects).first
          expect(results).to eq []
        end
      end

      it ".search with User.with_user joining tenant" do
        User.with_user(other_user) do
          other_user.miq_groups = [owner_group]
          other_user.save
          results = Rbac.search(:class => "Vm", :results_format => :objects).first
          expect(results).to eq [owned_vm]
        end
      end

      context "tenant access strategy of descendant_ids (children)" do
        it "can't see parent tenant's Vm" do
          results = Rbac.search(:class => "Vm", :results_format => :objects, :miq_group_id => child_group.id).first
          expect(results).to eq []
        end

        it "can see descendant tenant's Vms" do
          owned_vm.update_attributes(:tenant_id => child_tenant.id, :miq_group_id => child_group.id)
          expect(owned_vm.tenant).to eq child_tenant

          results = Rbac.search(:class => "Vm", :results_format => :objects, :miq_group_id => owner_group.id).first
          expect(results).to eq [owned_vm]
        end

        it "can see descendant tenant's Openstack Vm" do
          owned_openstack_vm

          results = Rbac.search(:class => "ManageIQ::Providers::Openstack::CloudManager::Vm", :results_format => :objects, :miq_group_id => owner_group.id).first
          expect(results).to eq [owned_openstack_vm]
        end
      end

      context "tenant access strategy of ancestor_ids (parents)" do
        it "can see parent tenant's EMS" do
          ems = FactoryGirl.create(:ems_vmware, :tenant => owner_tenant)
          results = Rbac.search(:class => "ExtManagementSystem", :results_format => :objects, :miq_group_id => child_group.id).first
          expect(results).to eq [ems]
        end

        it "can't see descendant tenant's EMS" do
          _ems = FactoryGirl.create(:ems_vmware, :tenant => child_tenant)
          results = Rbac.search(:class => "ExtManagementSystem", :results_format => :objects, :miq_group_id => owner_group.id).first
          expect(results).to eq []
        end
      end

      context "tenant access strategy of nil (tenant only)" do
        it "can see tenant's request task" do
          task = FactoryGirl.create(:miq_request_task, :tenant => owner_tenant)
          results = Rbac.search(:class => "MiqRequestTask", :results_format => :objects, :miq_group_id => owner_group.id).first
          expect(results).to eq [task]
        end

        it "can't see parent tenant's request task" do
          _task = FactoryGirl.create(:miq_request_task, :tenant => owner_tenant)
          results = Rbac.search(:class => "MiqRequestTask", :results_format => :objects, :miq_group_id => child_group.id).first
          expect(results).to eq []
        end

        it "can't see descendant tenant's request task" do
          _task = FactoryGirl.create(:miq_request_task, :tenant => child_tenant)
          results = Rbac.search(:class => "MiqRequestTask", :results_format => :objects, :miq_group_id => owner_group.id).first
          expect(results).to eq []
        end
      end

      context "tenant 0" do
        it "can see requests owned by any tenants" do
          request_task = FactoryGirl.create(:miq_request_task, :tenant => owner_tenant)
          t0_group = FactoryGirl.create(:miq_group, :tenant => default_tenant)
          results = Rbac.search(:class => "MiqRequestTask", :results_format => :objects, :miq_group_id => t0_group).first
          expect(results).to eq [request_task]
        end
      end
    end
  end

  context "common setup" do
    let(:group) { FactoryGirl.create(:miq_group) }
    let(:user) { FactoryGirl.create(:user, :miq_groups => [group]) }
    before(:each) do
      @tags = {
        2 => "/managed/environment/prod",
        3 => "/managed/environment/dev",
        4 => "/managed/service_level/gold",
        5 => "/managed/service_level/silver"
      }
    end

    context "with Hosts" do
      let(:hosts) { [@host1, @host2] }
      before(:each) do
        @host1 = FactoryGirl.create(:host, :name => "Host1", :hostname => "host1.local")
        @host2 = FactoryGirl.create(:host, :name => "Host2", :hostname => "host2.local")
      end

      context "having Metric data" do
        before(:each) do
          @timestamps = [
            ["2010-04-14T20:52:30Z", 100.0],
            ["2010-04-14T21:51:10Z", 1.0],
            ["2010-04-14T21:51:30Z", 2.0],
            ["2010-04-14T21:51:50Z", 4.0],
            ["2010-04-14T21:52:10Z", 8.0],
            ["2010-04-14T21:52:30Z", 15.0],
            ["2010-04-14T22:52:30Z", 100.0],
          ]
          @timestamps.each do |t, v|
            [@host1, @host2].each do |h|
              h.metric_rollups << FactoryGirl.create(:metric_rollup_host_hr,
                                                     :timestamp                  => t,
                                                     :cpu_usage_rate_average     => v,
                                                     :cpu_ready_delta_summation  => v * 1000, # Multiply by a factor of 1000 to maake it more realistic and enable testing virtual col v_pct_cpu_ready_delta_summation
                                                     :sys_uptime_absolute_latest => v
                                                    )
            end
          end
        end

        context "with only managed filters" do
          before(:each) do
            group.update_attributes(:filters => {"managed" => [["/managed/environment/prod"], ["/managed/service_level/silver"]], "belongsto" => []})

            @tags = ["/managed/environment/prod"]
            @host2.tag_with(@tags.join(' '), :ns => '*')
            @tags << "/managed/service_level/silver"
          end

          it ".search finds the right HostPerformance rows" do
            @host1.tag_with(@tags.join(' '), :ns => '*')
            results, attrs = Rbac.search(:class => "HostPerformance", :userid => user.userid, :results_format => :objects)
            expect(attrs[:user_filters]).to eq(group.filters)
            expect(attrs[:total_count]).to eq(@timestamps.length * hosts.length)
            expect(attrs[:auth_count]).to eq(@timestamps.length)
            expect(results.length).to eq(@timestamps.length)
            results.each { |vp| expect(vp.resource).to eq(@host1) }
          end

          it ".search filters out the wrong HostPerformance rows with :match_via_descendants option" do
            @vm = FactoryGirl.create(:vm_vmware, :name => "VM1", :host => @host2)
            @vm.tag_with(@tags.join(' '), :ns => '*')
            results, attrs = Rbac.search(:targets => HostPerformance.all, :class => "HostPerformance", :userid => user.userid, :results_format => :objects, :match_via_descendants => {"VmOrTemplate" => :host})
            expect(attrs[:user_filters]).to eq(group.filters)
            expect(attrs[:total_count]).to eq(@timestamps.length * hosts.length)
            expect(attrs[:auth_count]).to eq(@timestamps.length)
            expect(results.length).to eq(@timestamps.length)
            results.each { |vp| expect(vp.resource).to eq(@host2) }

            results, attrs = Rbac.search(:targets => HostPerformance.all, :class => "HostPerformance", :userid => user.userid, :results_format => :objects, :match_via_descendants => "Vm")
            expect(attrs[:user_filters]).to eq(group.filters)
            expect(attrs[:total_count]).to eq(@timestamps.length * hosts.length)
            expect(attrs[:auth_count]).to eq(@timestamps.length)
            expect(results.length).to eq(@timestamps.length)
            results.each { |vp| expect(vp.resource).to eq(@host2) }
          end

          it ".search filters out the wrong HostPerformance rows" do
            @host1.tag_with(@tags.join(' '), :ns => '*')
            results, attrs = Rbac.search(:targets => HostPerformance.all, :class => "HostPerformance", :userid => user.userid, :results_format => :objects)
            expect(attrs[:user_filters]).to eq(group.filters)
            expect(attrs[:total_count]).to eq(@timestamps.length * hosts.length)
            expect(attrs[:auth_count]).to eq(@timestamps.length)
            expect(results.length).to eq(@timestamps.length)
            results.each { |vp| expect(vp.resource).to eq(@host1) }
          end
        end

        context "with only belongsto filters" do
          before(:each) do
            group.update_attributes(:filters => {"managed" => [], "belongsto" => ["/belongsto/ExtManagementSystem|ems1"]})

            ems1 = FactoryGirl.create(:ems_vmware, :name => 'ems1')
            @host1.update_attributes(:ext_management_system => ems1)
            @host2.update_attributes(:ext_management_system => ems1)

            root = FactoryGirl.create(:ems_folder, :name => "Datacenters")
            root.parent = ems1
            dc = FactoryGirl.create(:ems_folder, :name => "Datacenter1")
            dc.parent = root
            hfolder   = FactoryGirl.create(:ems_folder, :name => "Hosts")
            hfolder.parent = dc
            @host1.parent = hfolder
          end

          it ".search finds the right HostPerformance rows" do
            results, attrs = Rbac.search(:class => "HostPerformance", :userid => user.userid, :results_format => :objects)
            expect(attrs[:user_filters]).to eq(group.filters)
            expect(attrs[:total_count]).to eq(@timestamps.length * hosts.length)
            expect(attrs[:auth_count]).to eq(@timestamps.length)
            expect(results.length).to eq(@timestamps.length)
            results.each { |vp| expect(vp.resource).to eq(@host1) }
          end

          it ".search filters out the wrong HostPerformance rows" do
            results, attrs = Rbac.search(:targets => HostPerformance.all, :class => "HostPerformance", :userid => user.userid, :results_format => :objects)
            expect(attrs[:user_filters]).to eq(group.filters)
            expect(attrs[:total_count]).to eq(@timestamps.length * hosts.length)
            expect(attrs[:auth_count]).to eq(@timestamps.length)
            expect(results.length).to eq(@timestamps.length)
            results.each { |vp| expect(vp.resource).to eq(@host1) }
          end
        end
      end

      context "with VMs and Templates" do
        before(:each) do
          @ems = FactoryGirl.create(:ems_vmware, :name => 'ems1')
          @host1.update_attributes(:ext_management_system => @ems)
          @host2.update_attributes(:ext_management_system => @ems)

          root            = FactoryGirl.create(:ems_folder, :name => "Datacenters")
          root.parent     = @ems
          dc              = FactoryGirl.create(:ems_folder, :name => "Datacenter1", :is_datacenter => true)
          dc.parent       = root
          hfolder         = FactoryGirl.create(:ems_folder, :name => "host")
          hfolder.parent  = dc
          @vfolder        = FactoryGirl.create(:ems_folder, :name => "vm")
          @vfolder.parent = dc
          @host1.parent   = hfolder
          @vm_folder_path = "/belongsto/ExtManagementSystem|#{@ems.name}/EmsFolder|#{root.name}/EmsFolder|#{dc.name}/EmsFolder|#{@vfolder.name}"

          @vm       = FactoryGirl.create(:vm_vmware,       :name => "VM1",       :host => @host1, :ext_management_system => @ems)
          @template = FactoryGirl.create(:template_vmware, :name => "Template1", :host => @host1, :ext_management_system => @ems)
        end

        it "honors ems_id conditions" do
          results = Rbac.search(:class => "ManageIQ::Providers::Vmware::InfraManager::Template", :conditions => ["ems_id IS NULL"], :results_format => :objects)
          objects = results.first
          expect(objects).to eq([])

          @template.update_attributes(:ext_management_system => nil)
          results = Rbac.search(:class => "ManageIQ::Providers::Vmware::InfraManager::Template", :conditions => ["ems_id IS NULL"], :results_format => :objects)
          objects = results.first
          expect(objects).to eq([@template])
        end

        context "search on EMSes" do
          before(:each) do
            @ems2 = FactoryGirl.create(:ems_vmware, :name => 'ems2')
          end

          it "preserves order of targets" do
            @ems3 = FactoryGirl.create(:ems_vmware, :name => 'ems3')
            @ems4 = FactoryGirl.create(:ems_vmware, :name => 'ems4')

            targets = [@ems2, @ems4, @ems3, @ems]

            results = Rbac.search(:targets => targets, :results_format => :objects, :userid => user.userid)
            objects = results.first
            expect(objects.length).to eq(4)
            expect(objects).to eq(targets)
          end

          it "finds both EMSes without belongsto filters" do
            results = Rbac.search(:class => "ExtManagementSystem", :results_format => :objects, :userid => user.userid)
            objects = results.first
            expect(objects.length).to eq(2)
          end

          it "finds one EMS with belongsto filters" do
            group.update_attributes(:filters => {"managed" => [], "belongsto" => [@vm_folder_path]})
            results = Rbac.search(:class => "ExtManagementSystem", :results_format => :objects, :userid => user.userid)
            objects = results.first
            expect(objects).to eq([@ems])
          end
        end

        it "search on VMs and Templates should return no objects if self-service user" do
          User.any_instance.stub(:self_service? => true)
          User.with_user(user) do
            results = Rbac.search(:class => "VmOrTemplate", :results_format => :objects)
            objects = results.first
            expect(objects.length).to eq(0)
          end
        end

        it "search on VMs and Templates should return both objects" do
          results = Rbac.search(:class => "VmOrTemplate", :results_format => :objects)
          objects = results.first
          expect(objects.length).to eq(2)
          expect(objects).to match_array([@vm, @template])

          group.update_attributes(:filters => {"managed" => [], "belongsto" => [@vm_folder_path]})
          results = Rbac.search(:class => "VmOrTemplate", :results_format => :objects, :userid => user.userid)
          objects = results.first
          expect(objects.length).to eq(0)

          [@vm, @template].each do |v|
            v.with_relationship_type("ems_metadata") { v.parent = @vfolder }
            v.save
          end

          group.update_attributes(:filters => {"managed" => [], "belongsto" => [@vm_folder_path]})
          results = Rbac.search(:class => "VmOrTemplate", :results_format => :objects, :userid => user.userid)
          objects = results.first
          expect(objects.length).to eq(2)
          expect(objects).to match_array([@vm, @template])
        end

        it "search on VMs should return a single object" do
          results = Rbac.search(:class => "Vm", :results_format => :objects)
          objects = results.first
          expect(objects.length).to eq(1)
          expect(objects).to match_array([@vm])

          group.update_attributes(:filters => {"managed" => [], "belongsto" => [@vm_folder_path]})

          results = Rbac.search(:class => "Vm", :results_format => :objects, :userid => user.userid)
          objects = results.first
          expect(objects.length).to eq(0)

          [@vm, @template].each do |v|
            v.with_relationship_type("ems_metadata") { v.parent = @vfolder }
            v.save
          end

          group.update_attributes(:filters => {"managed" => [], "belongsto" => [@vm_folder_path]})
          results = Rbac.search(:class => "Vm", :results_format => :objects, :userid => user.userid)
          objects = results.first
          expect(objects.length).to eq(1)
          expect(objects).to match_array([@vm])
        end

        it "search on Templates should return a single object" do
          results = Rbac.search(:class => "MiqTemplate", :results_format => :objects)
          objects = results.first
          expect(objects.length).to eq(1)
          expect(objects).to match_array([@template])

          group.update_attributes(:filters => {"managed" => [], "belongsto" => [@vm_folder_path]})

          results = Rbac.search(:class => "MiqTemplate", :results_format => :objects, :userid => user.userid)
          objects = results.first
          expect(objects.length).to eq(0)

          [@vm, @template].each do |v|
            v.with_relationship_type("ems_metadata") { v.parent = @vfolder }
            v.save
          end

          group.update_attributes(:filters => {"managed" => [], "belongsto" => [@vm_folder_path]})
          results = Rbac.search(:class => "MiqTemplate", :results_format => :objects, :userid => user.userid)
          objects = results.first
          expect(objects.length).to eq(1)
          expect(objects).to match_array([@template])
        end
      end

      context "when applying a filter to the host's cluster (FB17114)" do
        before(:each) do
          @ems = FactoryGirl.create(:ems_vmware, :name => 'ems')
          @ems_folder_path = "/belongsto/ExtManagementSystem|#{@ems.name}"
          @root = FactoryGirl.create(:ems_folder, :name => "Datacenters")
          @root.parent = @ems
          @mtc = FactoryGirl.create(:ems_folder, :name => "MTC", :is_datacenter => true)
          @mtc.parent = @root
          @mtc_folder_path = "/belongsto/ExtManagementSystem|#{@ems.name}/EmsFolder|#{@root.name}/EmsFolder|#{@mtc.name}"

          @hfolder         = FactoryGirl.create(:ems_folder, :name => "host")
          @hfolder.parent  = @mtc

          @cluster = FactoryGirl.create(:ems_cluster, :name => "MTC Development")
          @cluster.parent = @hfolder
          @cluster_folder_path = "#{@mtc_folder_path}/EmsFolder|#{@hfolder.name}/EmsCluster|#{@cluster.name}"

          @rp = FactoryGirl.create(:resource_pool, :name => "Default for MTC Development")
          @rp.parent = @cluster

          @host_1 = FactoryGirl.create(:host, :name => "Host_1", :ems_cluster => @cluster, :ext_management_system => @ems)
          @host_2 = FactoryGirl.create(:host, :name => "Host_2", :ext_management_system => @ems)

          @vm1 = FactoryGirl.create(:vm_vmware, :name => "VM1", :host => @host_1, :ext_management_system => @ems)
          @vm2 = FactoryGirl.create(:vm_vmware, :name => "VM2", :host => @host_2, :ext_management_system => @ems)

          @template1 = FactoryGirl.create(:template_vmware, :name => "Template1", :host => @host_1, :ext_management_system => @ems)
          @template2 = FactoryGirl.create(:template_vmware, :name => "Template2", :host => @host_2, :ext_management_system => @ems)
        end

        it "get all the descendants without belongsto filter" do
          results, attrs = Rbac.search(:class => "Host", :userid => user.userid, :results_format => :objects)
          expect(results.length).to eq(4)
          expect(attrs[:total_count]).to eq(4)
          expect(attrs[:auth_count]).to eq(4)
          expect(attrs[:user_filters]).to eq({"managed" => [], "belongsto" => []})

          results2 = Rbac.search(:class => "Vm", :userid => user.userid, :results_format => :objects).first
          expect(results2.length).to eq(2)

          results3 = Rbac.search(:class => "VmOrTemplate", :userid => user.userid, :results_format => :objects).first
          expect(results3.length).to eq(4)
        end

        it "get all the vm or templates with belongsto filter" do
          group.update_attributes(:filters => {"managed" => [], "belongsto" => [@cluster_folder_path]})
          results, attrs = Rbac.search(:class => "VmOrTemplate", :userid => user.userid, :results_format => :objects)
          expect(results.length).to eq(0)
          expect(attrs[:total_count]).to eq(4)
          expect(attrs[:auth_count]).to eq(0)

          [@vm1, @template1].each do |v|
            v.with_relationship_type("ems_metadata") { v.parent = @rp }
            v.save
          end
          group.update_attributes(:filters => {"managed" => [], "belongsto" => [@cluster_folder_path]})

          results2, attrs = Rbac.search(:class => "VmOrTemplate", :userid => user.userid, :results_format => :objects)
          expect(attrs[:user_filters]).to eq({"managed" => [], "belongsto" => [@cluster_folder_path]})
          expect(attrs[:total_count]).to eq(4)
          expect(attrs[:auth_count]).to eq(2)
          expect(results2.length).to eq(2)
        end

        it "get all the hosts with belongsto filter" do
          group.update_attributes(:filters => {"managed" => [], "belongsto" => [@cluster_folder_path]})
          results, attrs = Rbac.search(:class => "Host", :userid => user.userid, :results_format => :objects)
          expect(attrs[:user_filters]).to eq({"managed" => [], "belongsto" => [@cluster_folder_path]})
          expect(attrs[:total_count]).to eq(4)
          expect(attrs[:auth_count]).to eq(1)
          expect(results.length).to eq(1)

          group.update_attributes(:filters => {"managed" => [], "belongsto" => [@mtc_folder_path]})
          results2, attrs = Rbac.search(:class => "Host", :userid => user.userid, :results_format => :objects)
          expect(attrs[:user_filters]).to eq({"managed" => [], "belongsto" => [@mtc_folder_path]})
          expect(attrs[:total_count]).to eq(4)
          expect(attrs[:auth_count]).to eq(1)
          expect(results2.length).to eq(1)

          group.update_attributes(:filters => {"managed" => [], "belongsto" => [@ems_folder_path]})
          results3, attrs = Rbac.search(:class => "Host", :userid => user.userid, :results_format => :objects)
          expect(attrs[:user_filters]).to eq({"managed" => [], "belongsto" => [@ems_folder_path]})
          expect(attrs[:total_count]).to eq(4)
          expect(attrs[:auth_count]).to eq(1)
          expect(results3.length).to eq(1)
        end
      end
    end

    context "with services" do
      before(:each) do
        @service1 = FactoryGirl.create(:service)
        @service2 = FactoryGirl.create(:service)
        @service3 = FactoryGirl.create(:service, :evm_owner => user)
        @service4 = FactoryGirl.create(:service, :miq_group => group)
        @service5 = FactoryGirl.create(:service, :evm_owner => user, :miq_group => group)
      end

      context ".search" do
        it "self-service group" do
          MiqGroup.any_instance.stub(:self_service? => true)

          results = Rbac.search(:class => "Service", :results_format => :objects, :miq_group_id => user.current_group.id).first
          expect(results.to_a).to match_array([@service4, @service5])
        end

        context "with self-service user" do
          before(:each) do
            User.any_instance.stub(:self_service? => true)
          end

          it "works when targets are empty" do
            User.with_user(user) do
              results = Rbac.search(:class => "Service", :results_format => :objects).first
              expect(results.to_a).to match_array([@service3, @service4, @service5])
            end
          end
        end

        it "limited self-service group" do
          MiqGroup.any_instance.stub(:self_service? => true)
          MiqGroup.any_instance.stub(:limited_self_service? => true)

          results = Rbac.search(:class => "Service", :results_format => :objects, :miq_group_id => user.current_group.id).first
          expect(results.to_a).to match_array([@service4, @service5])
        end

        context "with limited self-service user" do
          before(:each) do
            User.any_instance.stub(:self_service? => true)
            User.any_instance.stub(:limited_self_service? => true)
          end

          it "works when targets are empty" do
            User.with_user(user) do
              results = Rbac.search(:class => "Service", :results_format => :objects).first
              expect(results.to_a).to match_array([@service3, @service5])
            end
          end
        end

        it "works when targets are a list of ids" do
          results = Rbac.search(:targets => Service.all.collect(&:id), :class => "Service", :results_format => :objects).first
          expect(results.length).to eq(5)
          expect(results.first).to be_kind_of(Service)

          results = Rbac.search(:targets => Service.all.collect(&:id), :class => "Service", :results_format => :ids).first
          expect(results.length).to eq(5)
          expect(results.first).to be_kind_of(Integer)
        end

        it "works when targets are empty" do
          results = Rbac.search(:class => "Service", :results_format => :objects).first
          expect(results.length).to eq(5)
        end
      end
    end

    context "with tagged VMs" do
      before(:each) do
        [
          FactoryGirl.create(:host, :name => "Host1", :hostname => "host1.local"),
          FactoryGirl.create(:host, :name => "Host2", :hostname => "host2.local"),
          FactoryGirl.create(:host, :name => "Host3", :hostname => "host3.local"),
          FactoryGirl.create(:host, :name => "Host4", :hostname => "host4.local")
        ].each_with_index do |host, i|
          grp = i + 1
          guest_os = %w(_none_ windows ubuntu windows ubuntu)[grp]
          vm = FactoryGirl.build(:vm_vmware, :name => "Test Group #{grp} VM #{i}")
          vm.hardware = FactoryGirl.build(:hardware, :cpu_sockets => (grp * 2), :memory_mb => (grp * 1.megabytes), :guest_os => guest_os)
          vm.host = host
          vm.evm_owner_id = user.id  if i.even?
          vm.miq_group_id = group.id if i.odd?
          vm.save
          vm.tag_with(@tags.values.join(" "), :ns => "*") if i > 0
        end

        Vm.scope :group_scope, ->(group_num) { Vm.where("name LIKE ?", "Test Group #{group_num}%") }
      end

      context ".search" do
        it "self-service group" do
          MiqGroup.any_instance.stub(:self_service? => true)

          results = Rbac.search(:class => "Vm", :results_format => :objects, :miq_group_id => user.current_group.id).first
          expect(results.length).to eq(2)
        end

        context "with self-service user" do
          before(:each) do
            User.any_instance.stub(:self_service? => true)
          end

          it "works when targets are empty" do
            User.with_user(user) do
              results = Rbac.search(:class => "Vm", :results_format => :objects).first
              expect(results.length).to eq(4)
            end
          end

          it "works when passing a named_scope" do
            User.with_user(user) do
              results = Rbac.search(:class => "Vm", :results_format => :objects, :named_scope => [:group_scope, 1]).first
              expect(results.length).to eq(1)
            end
          end
        end

        it "limited self-service group" do
          MiqGroup.any_instance.stub(:self_service? => true)
          MiqGroup.any_instance.stub(:limited_self_service? => true)

          results = Rbac.search(:class => "Vm", :results_format => :objects, :miq_group_id => user.current_group.id).first
          expect(results.length).to eq(2)
        end

        context "with limited self-service user" do
          before(:each) do
            User.any_instance.stub(:self_service? => true)
            User.any_instance.stub(:limited_self_service? => true)
          end

          it "works when targets are empty" do
            User.with_user(user) do
              results = Rbac.search(:class => "Vm", :results_format => :objects).first
              expect(results.length).to eq(2)
            end
          end

          it "works when passing a named_scope" do
            User.with_user(user) do
              results = Rbac.search(:class => "Vm", :results_format => :objects, :named_scope => [:group_scope, 1]).first
              expect(results.length).to eq(1)

              results = Rbac.search(:class => "Vm", :results_format => :objects, :named_scope => [:group_scope, 2]).first
              expect(results.length).to eq(0)
            end
          end
        end

        it "works when targets are a list of ids" do
          results = Rbac.search(:targets => Vm.all.collect(&:id), :class => "Vm", :results_format => :objects).first
          expect(results.length).to eq(4)
          expect(results.first).to be_kind_of(Vm)

          results = Rbac.search(:targets => Vm.all.collect(&:id), :class => "Vm", :results_format => :ids).first
          expect(results.length).to eq(4)
          expect(results.first).to be_kind_of(Integer)
        end

        it "works when targets are empty" do
          results = Rbac.search(:class => "Vm", :results_format => :objects).first
          expect(results.length).to eq(4)
        end

        it "works when passing a named_scope" do
          results = Rbac.search(:class => "Vm", :results_format => :objects, :named_scope => [:group_scope, 4]).first
          expect(results.length).to eq(1)
        end

        it "works when the filter is not fully supported in SQL (FB11080)" do
          filter = '--- !ruby/object:MiqExpression
          exp:
            or:
            - STARTS WITH:
                value: Test Group 1
                field: Vm-name
            - "=":
                value: Host2
                field: Vm-host_name
          '
          results = Rbac.search(:class => "Vm", :filter => YAML.load(filter), :results_format => :objects).first
          expect(results.length).to eq(2)
        end
      end

      context "with only managed filters (FB9153, FB11442)" do
        before(:each) do
          group.update_attributes(:filters => {"managed" => [["/managed/environment/prod"], ["/managed/service_level/silver"]], "belongsto" => []})
        end

        context ".search" do
          it "does not raise any errors when user filters are passed and search expression contains columns in a sub-table" do
            exp = YAML.load("--- !ruby/object:MiqExpression
            exp:
              and:
              - IS NOT EMPTY:
                  field: Vm.host-name
              - IS NOT EMPTY:
                  field: Vm-name
            ")
            expect { Rbac.search(:class => "Vm", :filter => exp, :userid => user.userid, :results_format => :objects, :order => "vms.name desc") }.not_to raise_error
          end

          it "works when limit, offset and user filters are passed and search expression contains columns in a sub-table" do
            exp = YAML.load("--- !ruby/object:MiqExpression
            exp:
              and:
              - IS NOT EMPTY:
                  field: Vm.host-name
              - IS NOT EMPTY:
                  field: Vm-name
            ")
            results, attrs = Rbac.search(:class => "Vm", :filter => exp, :userid => user.userid, :results_format => :objects, :limit => 2, :offset => 2, :order => "vms.name desc")
            expect(results.length).to eq(1)
            expect(results.first.name).to eq("Test Group 2 VM 1")
            expect(attrs[:auth_count]).to eq(3)
            expect(attrs[:total_count]).to eq(4)
          end

          it "works when class does not participate in RBAC and user filters are passed" do
            2.times do |i|
              FactoryGirl.create(:ems_event, :timestamp => Time.now.utc, :message => "Event #{i}")
            end

            report = MiqReport.new(:db => "EmsEvent")
            exp = YAML.load '--- !ruby/object:MiqExpression
            exp:
              IS:
                field: EmsEvent-timestamp
                value: Today
            '

            results, attrs = Rbac.search(:class => "EmsEvent", :filter => exp, :userid => user.userid, :results_format => :objects)

            expect(results.length).to eq(2)
            expect(attrs[:auth_count]).to eq(2)
            expect(attrs[:user_filters]["managed"]).to eq(group.filters['managed'])
            expect(attrs[:total_count]).to eq(2)
          end
        end
      end
    end

    context "Evaluating date/time expressions" do
      before(:each) do
        Timecop.freeze("2011-01-11 17:30 UTC")

        user.settings = {:display => {:timezone => "Eastern Time (US & Canada)"}}
        user.save
        @host1 = FactoryGirl.create(:host)
        @host2 = FactoryGirl.create(:host)

        # VMs hours apart
        (0...20).each do |i|
          FactoryGirl.create(:vm_vmware, :name => "VM Hour #{i}", :last_scan_on => i.hours.ago.utc, :retires_on => i.hours.ago.utc.to_date, :host => @host1)
        end

        # VMs days apart
        (0...15).each do |i|
          FactoryGirl.create(:vm_vmware, :name => "VM Day #{i}", :last_scan_on => i.days.ago.utc, :retires_on => i.days.ago.utc.to_date, :host => @host2)
        end

        # VMs weeks apart
        (0...10).each do |i|
          FactoryGirl.create(:vm_vmware, :name => "VM Week #{i}", :last_scan_on => i.weeks.ago.utc, :retires_on => i.weeks.ago.utc.to_date, :host => @host2)
        end

        # VMs months apart
        (0...10).each do |i|
          FactoryGirl.create(:vm_vmware, :name => "VM Month #{i}", :last_scan_on => i.months.ago.utc, :retires_on => i.months.ago.utc.to_date, :host => @host2)
        end

        # VMs quarters apart
        (0...5).each do |i|
          FactoryGirl.create(:vm_vmware, :name => "VM Quarter #{i}", :last_scan_on => (i * 3).months.ago.utc, :retires_on => (i * 3).months.ago.utc.to_date, :host => @host2)
        end

        # VMs with nil dates/times
        (0...2).each do |i|
          FactoryGirl.create(:vm_vmware, :name => "VM Quarter #{i}", :host => @host2)
        end
      end

      after(:each) do
        Timecop.return
      end

      it "should return the correct results when searching with a date/time filter" do
        # Vm.all(:order => "last_scan_on").each {|v| puts " #{v.last_scan_on ? v.last_scan_on.iso8601 : "nil"} => #{v.name} -> #{v.host_id}"}

        # Test >, <, >=, <=
        result = Rbac.search(:class => "Vm", :filter => MiqExpression.new("AFTER" => {"field" => "Vm-last_scan_on", "value" => "2011-01-11 9:00"})).first
        expect(result.length).to eq(13)

        result = Rbac.search(:class => "Vm", :filter => MiqExpression.new(">" => {"field" => "Vm-last_scan_on", "value" => "2011-01-11 9:00"})).first
        expect(result.length).to eq(13)

        # Test IS EMPTY and IS NOT EMPTY
        result = Rbac.search(:class => "Vm", :filter => MiqExpression.new("IS EMPTY" => {"field" => "Vm-last_scan_on"})).first
        expect(result.length).to eq(2)

        result = Rbac.search(:class => "Vm", :filter => MiqExpression.new("IS EMPTY" => {"field" => "Vm-retires_on"})).first
        expect(result.length).to eq(2)

        result = Rbac.search(:class => "Vm", :filter => MiqExpression.new("IS NOT EMPTY" => {"field" => "Vm-last_scan_on"})).first
        expect(result.length).to eq(60)

        result = Rbac.search(:class => "Vm", :filter => MiqExpression.new("IS NOT EMPTY" => {"field" => "Vm-retires_on"})).first
        expect(result.length).to eq(60)

        # Test IS
        result = Rbac.search(:class => "Vm", :filter => MiqExpression.new("IS" => {"field" => "Vm-retires_on", "value" => "2011-01-10"})).first
        expect(result.length).to eq(3)

        result = Rbac.search(:class => "Vm", :filter => MiqExpression.new("IS" => {"field" => "Vm-last_scan_on", "value" => "2011-01-11"})).first
        expect(result.length).to eq(22)

        result = Rbac.search(:class => "Vm", :filter => MiqExpression.new("IS" => {"field" => "Vm-last_scan_on", "value" => "Today"})).first
        expect(result.length).to eq(22)

        result = Rbac.search(:class => "Vm", :filter => MiqExpression.new("IS" => {"field" => "Vm-last_scan_on", "value" => "3 Hours Ago"})).first
        expect(result.length).to eq(1)

        result = Rbac.search(:class => "Vm", :filter => MiqExpression.new("IS" => {"field" => "Vm-retires_on", "value" => "3 Hours Ago"})).first
        expect(result.length).to eq(22)

        result = Rbac.search(:class => "Vm", :filter => MiqExpression.new("IS" => {"field" => "Vm-last_scan_on", "value" => "Last Month"})).first
        expect(result.length).to eq(9)

        # Test FROM
        result = Rbac.search(:class  => "Vm",
                             :filter => MiqExpression.new(
                               "FROM" => {"field" => "Vm-last_scan_on", "value" => ["2010-07-11", "2010-12-31"]}
                             )).first
        expect(result.length).to eq(20)

        result = Rbac.search(:class  => "Vm",
                             :filter => MiqExpression.new(
                               "FROM" => {"field" => "Vm-retires_on", "value" => ["2010-07-11", "2010-12-31"]}
                             )).first
        expect(result.length).to eq(20)

        result = Rbac.search(:class  => "Vm",
                             :filter => MiqExpression.new(
                               "FROM" => {"field" => "Vm-last_scan_on", "value" => ["2011-01-09 17:00", "2011-01-10 23:30:59"]}
                             )).first
        expect(result.length).to eq(4)

        result = Rbac.search(:class => "Vm", :filter => MiqExpression.new("FROM" => {"field" => "Vm-retires_on", "value" => ["Last Week", "Last Week"]})).first
        expect(result.length).to eq(8)

        result = Rbac.search(:class => "Vm", :filter => MiqExpression.new("FROM" => {"field" => "Vm-last_scan_on", "value" => ["Last Week", "Last Week"]})).first
        expect(result.length).to eq(8)

        result = Rbac.search(:class => "Vm", :filter => MiqExpression.new("FROM" => {"field" => "Vm-last_scan_on", "value" => ["Last Week", "This Week"]})).first
        expect(result.length).to eq(33)

        result = Rbac.search(:class => "Vm", :filter => MiqExpression.new("FROM" => {"field" => "Vm-last_scan_on", "value" => ["2 Months Ago", "1 Month Ago"]})).first
        expect(result.length).to eq(14)

        result = Rbac.search(:class => "Vm", :filter => MiqExpression.new("FROM" => {"field" => "Vm-last_scan_on", "value" => ["Last Month", "Last Month"]})).first
        expect(result.length).to eq(9)

        # Inside a find/check expression
        result = Rbac.search(:class => "Host", :filter => MiqExpression.new(
          "FIND" => {
            "checkany" => {"FROM" => {"field" => "Host.vms-last_scan_on", "value" => ["2011-01-08 17:00", "2011-01-09 23:30:59"]}},
            "search"   => {"IS NOT NULL" => {"field" => "Host.vms-name"}}}
        )).first
        expect(result.length).to eq(1)

        result = Rbac.search(:class => "Host", :filter => MiqExpression.new(
          "FIND" => {
            "search"   => {"FROM" => {"field" => "Host.vms-last_scan_on", "value" => ["2011-01-08 17:00", "2011-01-09 23:30:59"]}},
            "checkall" => {"IS NOT NULL" => {"field" => "Host.vms-name"}}}
        )).first
        expect(result.length).to eq(1)

        # Test FROM with time zone
        result = Rbac.search(:class  => "Vm",
                             :userid => user.userid,
                             :filter => MiqExpression.new(
                               "FROM" => {"field" => "Vm-last_scan_on", "value" => ["2011-01-09 17:00", "2011-01-10 23:30:59"]}
                             )).first
        expect(result.length).to eq(8)

        # Test IS with time zone
        result = Rbac.search(:class  => "Vm",
                             :userid => user.userid,
                             :filter => MiqExpression.new("IS" => {"field" => "Vm-retires_on", "value" => "2011-01-10"})
                            ).first
        expect(result.length).to eq(3)

        result = Rbac.search(:class  => "Vm",
                             :userid => user.userid,
                             :filter => MiqExpression.new("IS" => {"field" => "Vm-last_scan_on", "value" => "2011-01-11"})
                            ).first
        expect(result.length).to eq(17)

        # TODO: More tests with time zone
      end
    end

    context "with group's VMs" do
      before(:each) do
        role2 = FactoryGirl.create(:miq_user_role, :name => 'support')
        group2 = FactoryGirl.create(:miq_group, :description => "Support Group", :miq_user_role => role2)
        4.times do |i|
          case i
          when 0
            group_id = group.id
            state = 'connected'
          when 1
            group_id = group2.id
            state = 'connected'
          when 2
            group_id = group.id
            state = 'disconnected'
          when 3
            group_id = group2.id
            state = 'disconnected'
          end
          vm = FactoryGirl.create(:vm_vmware, :name => "Test VM #{i}", :connection_state => state, :miq_group_id => group_id)
        end
      end

      it "when filtering on a real column" do
        filter = YAML.load '--- !ruby/object:MiqExpression
        context_type:
        exp:
          CONTAINS:
            value: connected
            field: MiqGroup.vms-connection_state
        '
        results, attrs = described_class.search(:class => "MiqGroup", :filter => filter, :results_format => :objects)

        expect(results.length).to eq(2)
        expect(attrs[:total_count]).to eq(2)
      end

      it "when filtering on a virtual column (FB15509)" do
        filter = YAML.load '--- !ruby/object:MiqExpression
        context_type:
        exp:
          CONTAINS:
            value: false
            field: MiqGroup.vms-disconnected
        '
        results, attrs = described_class.search(:class => "MiqGroup", :userid => "admin", :filter => filter, :results_format => :objects)

        expect(results.length).to eq(2)
        expect(attrs[:total_count]).to eq(2)
      end
    end

    context "database configuration" do
      it "expect all database setting values returned" do
        results = Rbac.search(:class               => "VmdbDatabaseSetting",
                              :userid              => "admin",
                              :parent              => nil,
                              :parent_method       => nil,
                              :targets_hash        => true,
                              :association         => nil,
                              :filter              => nil,
                              :sub_filter          => nil,
                              :where_clause        => nil,
                              :named_scope         => nil,
                              :display_filter_hash => nil,
                              :conditions          => nil,
                              :results_format      => :objects,
                              :include_for_find    => {:description => {}, :minimum_value => {}, :maximum_value => {}}
                             ).first

        expect(results.length).to eq(VmdbDatabaseSetting.all.length)
      end
    end
  end

  describe ".filter" do
    let(:vm_location_filter) do
      MiqExpression.new("=" => {"field" => "Vm-location", "value" => "good"})
    end

    let(:matched_vms) { FactoryGirl.create_list(:vm_vmware, 2, :location => "good") }
    let(:other_vms)   { FactoryGirl.create_list(:vm_vmware, 1, :location => "other") }
    let(:all_vms)     { matched_vms + other_vms }
    let(:partial_matched_vms) { [matched_vms.first] }
    let(:partial_vms) { partial_matched_vms + other_vms }

    it "skips rbac on empty empty arrays" do
      all_vms
      expect(Rbac.filtered([], :class => Vm)).to eq([])
    end

    # TODO: return all_vms
    it "skips rbac on nil targets" do
      all_vms
      expect(Rbac.filtered(nil, :class => Vm)).to be_nil
    end

    # it returns objects too
    # TODO: cap number of queries here
    it "runs rbac on array target" do
      all_vms
      expect(Rbac.filtered(all_vms, :class => Vm)).to match_array(all_vms)
    end
  end

  # -------------------------------
  # find targets with rbac are split up into 4 types

  # determine what to run
  it ".apply_rbac_to_class?" do
    expect(Rbac.apply_rbac_to_class?(Vm)).to be
    expect(Rbac.apply_rbac_to_class?(Rbac)).not_to be
  end

  it ".apply_rbac_to_associated_class?" do
    expect(Rbac.apply_rbac_to_associated_class?(HostMetric)).to be
    expect(Rbac.apply_rbac_to_associated_class?(Vm)).not_to be
  end

  it ".apply_user_group_rbac_to_class?" do
    expect(Rbac.apply_user_group_rbac_to_class?(User)).to be
    expect(Rbac.apply_user_group_rbac_to_class?(Vm)).not_to be
  end

  # find_targets_with_direct_rbac(klass, scope, rbac_filters, find_options, user_or_group)
  describe "find_targets_with_direct_rbac" do
    let(:host_filter_find_options) do
      {:conditions => {"hosts.hostname" => "good"}, :include => "host"}
    end

    let(:host_match) { FactoryGirl.create(:host, :hostname => 'good') }
    let(:host_other) { FactoryGirl.create(:host, :hostname => 'bad') }
    let(:vms_match) { FactoryGirl.create_list(:vm_vmware, 2, :host => host_match) }
    let(:vm_host2) { FactoryGirl.create_list(:vm_vmware, 1, :host => host_other) }
    let(:all_vms) { vms_match + vm_host2 }

    it "works with no filters" do
      all_vms
      result = Rbac.find_targets_with_direct_rbac(Vm, Vm, {})
      expect_counts(result, all_vms, all_vms.size, all_vms.size)
    end

    # most of the functionality of search is channeled through find_options. including filters
    # including :conditions, :include, :order, :limit
    it "applies find_options[:conditions, :include]" do
      all_vms
      result = Rbac.find_targets_with_direct_rbac(Vm, Vm, {}, host_filter_find_options)
      expect_counts(result, vms_match, 2, 2)
    end
  end

  private

  # separate them to match easier for failures
  def expect_counts(actual, expected_targets, expected_count, expected_auth_count)
    expect(actual[1]).to eq(expected_count)
    expect(actual[2]).to eq(expected_auth_count)
    expect(actual[0].to_a).to match_array(expected_targets)
  end
end
