<?php if ( ! defined('BASEPATH')) exit('No direct script access allowed');

class Systems extends CI_Controller {

	public function index()
	{
		echo "You are working with a system<br>";
	}
	
	public function view($system_name=NULL)
	{
		if (!$system_name)
		{
			echo "Need to specify system<br>";
			die;
		}

		$skin = "grid";
		
		$system_info = $this->api->get_system_info($system_name);
		echo link_tag("css/$skin/full/main.css");

		$this->load->view("systems/system",$system_info);
		$interface_info = $this->api->get_system_interfaces($system_name);
		
		foreach ($interface_info as $interface)
		{
			$this->load->view("systems/interface",$interface);

			$address_info = $this->api->get_interface_addresses($interface['mac']);
			foreach ($address_info as $address)
			{
				$this->load->view("ip/address",$address);
				
				$fw_rules_info = $this->api->get_address_rules($address['address']);
				$rules['stdrules'] = array();
				$rules['stdprogs'] = array();
				foreach ($fw_rules_info as $rule)
				{
					switch($rule['source'])
					{
						case 'standalone-standalone':
							array_push($rules['stdrules'], $rule);
							break;
						case 'standalone-program':
							array_push($rules['stdprogs'], $rule);
							break;
					}
				}
				if(count($rules['stdrules']) > 0)
				{
					$this->load->view("firewall/standalone-rules",$rules);
				}
				if(count($rules['stdprogs']) > 0)
				{
					$this->load->view("firewall/standalone-programs",$rules);
				}
			}
		}
	}
	
	public function edit($system_name=NULL)
	{
		if (!$system_name)
		{
			echo "Need to specify system<br>";
			die;
		}
		
		
		echo "Editing system \"$system_name\"";
	}
}
/* End of file system.php */
/* Location: ./application/controllers/system.php */
