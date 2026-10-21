require "./concentration_measurement_definition"

module Matter
  module Cluster
    # Carbon Dioxide Concentration Measurement (0x040D), Matter 1.6 revision 5.
    class CarbonDioxideConcentrationMeasurement < Base
      cluster 0x040D, revision: 5
      include ConcentrationMeasurementDefinition
      attribute 0x0009, :measurement_medium, MeasurementMedium, default: MeasurementMedium::Air, fixed: true
    end
  end
end
