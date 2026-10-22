require "./concentration_measurement_definition"

module Matter
  module Cluster
    # Matter 1.6 FormaldehydeConcentrationMeasurement (revision 5).
    class FormaldehydeConcentrationMeasurement < Base
      cluster 0x042B, revision: 5
      include ConcentrationMeasurementDefinition
      attribute 0x0009, :measurement_medium, MeasurementMedium, default: MeasurementMedium::Air, fixed: true
    end
  end
end
