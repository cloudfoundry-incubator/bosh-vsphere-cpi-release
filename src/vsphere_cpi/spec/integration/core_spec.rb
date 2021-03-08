require 'integration/spec_helper'

context 'exercising core CPI functionality' do

  let(:network_spec) do
    {
      'static' => {
        'ip' => "192.168.111.100",
        'netmask' => '255.255.255.0',
        'cloud_properties' => {'name' => vlan},
        'default' => ['dns', 'gateway'],
        'dns' => ['8.8.8.8'],
        'gateway' => '192.168.111.1'
      }
    }
  end

  let(:vlan) { @vlan }

  let(:vm_type) do
    {
      'ram' => 512,
      'disk' => 2048,
      'cpu' => 1,
    }
  end

  context 'without existing disks' do
    it 'should exercise the vm lifecycle' do
      vm_lifecycle(@cpi, [], vm_type, network_spec, @stemcell_id) do |vm_id|
        vm = @cpi.vm_provider.find(vm_id)
        require 'pry'
        binding.pry
      end
    end
  end

  describe 'deleting things that do not exist' do
    it 'raises the appropriate Clouds::Error' do
      expect {
        @cpi.delete_vm('fake-vm-cid')
      }.to raise_error(Bosh::Clouds::VMNotFound)

      expect {
        @cpi.delete_disk('fake-disk-cid')
      }.to raise_error(Bosh::Clouds::DiskNotFound)
    end
  end

  context 'without existing disks' do
    it 'should exercise the vm lifecycle' do
      vm_lifecycle(@cpi, [], vm_type, network_spec, @stemcell_id)
    end
  end

  context 'with existing disks' do
    before { @existing_volume_id = @cpi.create_disk(2048, {}) }
    after { delete_disk(@cpi, @existing_volume_id) }

    it 'should exercise the vm lifecycle' do
      vm_lifecycle(@cpi, [@existing_volume_id], vm_type, network_spec, @stemcell_id)
    end
  end
end
