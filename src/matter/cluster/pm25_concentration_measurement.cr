require "./concentration_measurement_definition"

module Matter
  module Cluster
    # Matter 1.6 Pm25ConcentrationMeasurement (revision 5).
    class Pm25ConcentrationMeasurement < Base
      cluster 0x042A, revision: 5
      include ConcentrationMeasurementDefinition
      attribute 0x0009, :measurement_medium, MeasurementMedium, default: MeasurementMedium::Air, fixed: true
    end
  end
end
