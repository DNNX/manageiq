require "spec_helper"

describe MiqWorker do
  context "::Runner" do
    def all_workers
      MiqWorker.descendants.select { |c| c.subclasses.empty? }
    end

    it "finds the correct corresponding runner for workers" do
      all_workers.each do |worker|
        # If this isn't true, we're probably accidentally inheriting the
        # runner from a superclass
        expect(worker::Runner.name).to eq("#{worker.name}::Runner")
      end
    end
  end

  context ".sync_workers" do
    it "stops extra workers, returning deleted pids" do
      expect_any_instance_of(described_class).to receive(:stop)
      worker = FactoryGirl.create(:miq_worker, :status => "started")
      worker.class.workers = 0
      expect(worker.class.sync_workers).to eq({:adds => [], :deletes => [worker.pid]})
    end
  end

  context ".has_required_role?" do
    def check_has_required_role(worker_role_names, expected_result)
      allow(described_class).to receive(:required_roles).and_return(worker_role_names)
      expect(described_class.has_required_role?).to eq(expected_result)
    end

    before(:each) do
      active_roles = %w(foo bar).map { |rn| FactoryGirl.create(:server_role, :name => rn) }
      @server = EvmSpecHelper.local_miq_server(:active_roles => active_roles)
    end

    context "clean_active_messages" do
      before do
        allow_any_instance_of(MiqWorker).to receive(:set_command_line)
        @worker = FactoryGirl.create(:miq_worker, :miq_server => @server)
        @message = FactoryGirl.create(:miq_queue, :handler => @worker, :state => 'dequeue')
      end

      it "normal" do
        expect(@worker.active_messages.length).to eq(1)
        @worker.clean_active_messages
        expect(@worker.reload.active_messages.length).to eq(0)
      end

      it "invokes a message callback" do
        @message.update_attribute(:miq_callback, :class_name => 'Kernel', :method_name => 'rand')
        expect(Kernel).to receive(:rand)
        @worker.clean_active_messages
      end
    end

    it "when worker roles is nil" do
      check_has_required_role(nil, true)
    end

    context "when worker roles is a string" do
      it "that is blank" do
        check_has_required_role(" ", true)
      end

      it "that is one of the server roles" do
        check_has_required_role("foo", true)
      end

      it "that is not one of the server roles" do
        check_has_required_role("baa", false)
      end
    end

    context "when worker roles is an array" do
      it "that is empty" do
        check_has_required_role([], true)
      end

      it "that is a subset of server roles" do
        check_has_required_role(["foo"], true)
        check_has_required_role(["bah", "foo"], true)
      end

      it "that is not a subset of server roles" do
        check_has_required_role(["bah"], false)
      end
    end
  end

  context ".workers_configured_count" do
    before(:each) do
      @configured_count = 2
      allow(described_class).to receive(:worker_settings).and_return(:count => @configured_count)
      @maximum_workers_count = described_class.maximum_workers_count
    end

    after(:each) do
      described_class.maximum_workers_count = @maximum_workers_count
    end

    it "when maximum_workers_count is nil" do
      expect(described_class.workers_configured_count).to eq(@configured_count)
    end

    it "when maximum_workers_count is less than configured_count" do
      described_class.maximum_workers_count = 1
      expect(described_class.workers_configured_count).to eq(1)
    end

    it "when maximum_workers_count is equal to the configured_count" do
      described_class.maximum_workers_count = 2
      expect(described_class.workers_configured_count).to eq(@configured_count)
    end

    it "when maximum_workers_count is greater than configured_count" do
      described_class.maximum_workers_count = 2
      expect(described_class.workers_configured_count).to eq(@configured_count)
    end
  end

  context "with two servers" do
    before(:each) do
      allow(described_class).to receive(:nice_increment).and_return("+10")

      @zone = FactoryGirl.create(:zone)
      @server = FactoryGirl.create(:miq_server, :zone => @zone)
      allow(MiqServer).to receive(:my_server).and_return(@server)
      @worker = FactoryGirl.create(:miq_ems_refresh_worker, :miq_server => @server)

      @server2 = FactoryGirl.create(:miq_server, :zone => @zone)
      @worker2 = FactoryGirl.create(:miq_ems_refresh_worker, :miq_server => @server2)
    end

    it ".server_scope" do
      expect(described_class.server_scope).to eq([@worker])
    end

    it ".server_scope with a different server" do
      expect(described_class.server_scope(@server2.id)).to eq([@worker2])
    end

    it ".server_scope after already scoping on a different server" do
      described_class.where(:miq_server_id => @server2.id).scoping do
        expect(described_class.server_scope).to eq([@worker2])
        expect(described_class.server_scope(@server.id)).to eq([@worker2])
      end
    end

    context "worker_settings" do
      before do
        @config1 = {
          :workers => {
            :worker_base => {
              :defaults          => {:count => 1},
              :queue_worker_base => {
                :defaults           => {:count => 3},
                :ems_refresh_worker => {:count => 5}
              }
            }
          }
        }

        @config2 = {
          :workers => {
            :worker_base => {
              :defaults          => {:count => 2},
              :queue_worker_base => {
                :defaults           => {:count => 4},
                :ems_refresh_worker => {:count => 6}
              }
            }
          }
        }
        allow(@server).to receive(:get_config).with("vmdb").and_return(@config1)
        allow(@server2).to receive(:get_config).with("vmdb").and_return(@config2)
      end

      context "#worker_settings" do
        it "uses the worker's server" do
          expect(@worker.worker_settings[:count]).to eq(5)
          expect(@worker2.worker_settings[:count]).to eq(6)
        end

        it "uses passed in config" do
          expect(@worker.worker_settings(:config => @config2)[:count]).to eq(6)
          expect(@worker2.worker_settings(:config => @config1)[:count]).to eq(5)
        end

        it "uses closest parent's defaults" do
          @config1[:workers][:worker_base][:queue_worker_base][:ems_refresh_worker].delete(:count)
          expect(@worker.worker_settings[:count]).to eq(3)
        end
      end

      context ".worker_settings" do
        it "uses MiqServer.my_server" do
          expect(MiqEmsRefreshWorker.worker_settings[:count]).to eq(5)
        end

        it "uses passed in config" do
          expect(MiqEmsRefreshWorker.worker_settings(:config => @config2)[:count]).to eq(6)
        end
      end
    end
  end

  context "instance" do
    before(:each) do
      allow(described_class).to receive(:nice_increment).and_return("+10")
      @worker = FactoryGirl.create(:miq_worker)
    end

    it "is_current? false when starting" do
      @worker.update_attribute(:status, described_class::STATUS_STARTING)
      expect(@worker.is_current?).not_to be_truthy
    end

    it "is_current? true when started" do
      @worker.update_attribute(:status, described_class::STATUS_STARTED)
      expect(@worker.is_current?).to be_truthy
    end

    it "is_current? true when working" do
      @worker.update_attribute(:status, described_class::STATUS_WORKING)
      expect(@worker.is_current?).to be_truthy
    end
  end
end
