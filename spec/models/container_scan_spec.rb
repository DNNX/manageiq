require "spec_helper"

class MockClient
  def create_pod(*_args)
    nil
  end

  def proxy_url(*_args)
    'http://test.com'
  end

  def headers(*_args)
    []
  end

  def get_pod(*_args)
    RecursiveOpenStruct.new(
      :metadata => {
        :annotations => {
          'manageiq.org/jobid' => '5'
        }
      }
    )
  end
end

describe ManageIQ::Providers::Kubernetes::ContainerManager::Scanning::Job do
  context "A single Container Scan Job," do
    before(:each) do
      @server = EvmSpecHelper.local_miq_server

      described_class.any_instance.stub(:kubernetes_client => MockClient.new)

      @ems = FactoryGirl.create(
        :ems_kubernetes, :hostname => "test.com", :zone => @server.zone, :port => 8443,
        :authentications => [AuthToken.new(:name => "test", :type => 'AuthToken', :auth_key => "a secret")]
      )

      @image = FactoryGirl.create(
        :container_image, :ext_management_system => @ems, :name => 'test',
        :image_ref => 'docker://3629a651e6c11d7435937bdf41da11cf87863c03f2587fa788cf5cbfe8a11b9a'
      )

      allow_any_instance_of(@image.class).to receive(:scan_metadata) do |_instance, _args|
        @job.signal(:data, '<summary><scanmetadata></scanmetadata></summary>')
      end

      allow_any_instance_of(@image.class).to receive(:sync_metadata) do |_instance, _args|
        @job.signal(:data, '<summary><syncmetadata></syncmetadata></summary>')
      end

      @job = @image.scan
      allow(MiqQueue).to receive(:put_unless_exists) do |args|
        @job.signal(*args[:args])
      end
    end

    it 'should report success' do
      VCR.use_cassette(described_class.name.underscore, :record => :none) do # needed for health check
        expect(@job.state).to eq 'waiting_to_start'
        @job.signal(:start)
        expect(@job.state).to eq 'finished'
        expect(@job.status).to eq 'ok'
      end
    end

    context 'when the job is called with a non existing image' do
      before(:each) do
        @image.delete
      end

      it 'should report the error' do
        @job.signal(:start)
        expect(@job.state).to eq 'finished'
        expect(@job.status).to eq 'error'
        expect(@job.message).to eq "no image found"
      end
    end

    context 'when create pod throws exception' do
      CODE = 0
      CLIENT_MESSAGE = 'error'
      before(:each) do
        allow_any_instance_of(MockClient).to receive(:create_pod) do |_instance, *_args|
          raise KubeException.new(CODE, CLIENT_MESSAGE, nil)
        end
      end

      it 'should report the error' do
        @job.signal(:start)
        expect(@job.state).to eq 'finished'
        expect(@job.status).to eq 'error'
        expect(@job.message).to eq "pod creation for management-infra/manageiq-img-scan-3629a651e6c1" \
                               " failed: HTTP status code #{CODE}, #{CLIENT_MESSAGE}"
      end
    end
  end
end
