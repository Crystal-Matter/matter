# Cluster framework and every server cluster implementation.
module Matter
  module Cluster
    # Fallback logger for cluster files that do not define their own `Log`.
    Log = ::Log.for("matter.cluster")
  end
end

require "./cluster/cluster"
require "./cluster/registry"
require "./cluster/label_struct"

require "./cluster/color_control_utils"

require "./cluster/access_control"
require "./cluster/administrator_commissioning"
require "./cluster/basic_information"
require "./cluster/binding"
require "./cluster/boolean_state"
require "./cluster/bridged_device_basic_information"
require "./cluster/carbon_dioxide_concentration_measurement"
require "./cluster/color_control"
require "./cluster/descriptor"
require "./cluster/diagnostic_logs"
require "./cluster/door_lock"
require "./cluster/ethernet_network_diagnostics"
require "./cluster/fan_control"
require "./cluster/fixed_label"
require "./cluster/general_commissioning"
require "./cluster/general_diagnostics"
require "./cluster/group_key_management"
require "./cluster/groups"
require "./cluster/icd_management"
require "./cluster/identify"
require "./cluster/illuminance_measurement"
require "./cluster/joint_fabric_administrator"
require "./cluster/joint_fabric_datastore"
require "./cluster/level_control"
require "./cluster/network_commissioning"
require "./cluster/occupancy_sensing"
require "./cluster/on_off"
require "./cluster/operational_credentials"
require "./cluster/ota_requestor"
require "./cluster/power_source"
require "./cluster/pressure_measurement"
require "./cluster/relative_humidity_measurement"
require "./cluster/scenes_management"
require "./cluster/temperature_measurement"
require "./cluster/thermostat"
require "./cluster/time_format_localization"
require "./cluster/user_label"
require "./cluster/window_covering"
