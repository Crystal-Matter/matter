require "./concentration_measurement_definition"

module Matter
  module Cluster
    # Matter 1.6 TotalVolatileOrganicCompoundsConcentrationMeasurement (revision 5).
    class TotalVolatileOrganicCompoundsConcentrationMeasurement < Base
      cluster 0x042E, revision: 5
      include ConcentrationMeasurementDefinition
      attribute 0x0009, :measurement_medium, MeasurementMedium, default: MeasurementMedium::Air, fixed: true
    end
  end
end
