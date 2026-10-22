require "./concentration_measurement_definition"

module Matter
  module Cluster
    # Matter 1.6 RadonConcentrationMeasurement (revision 5).
    class RadonConcentrationMeasurement < Base
      cluster 0x042F, revision: 5
      include ConcentrationMeasurementDefinition
      attribute 0x0009, :measurement_medium, MeasurementMedium, default: MeasurementMedium::Air, fixed: true
    end
  end
end
