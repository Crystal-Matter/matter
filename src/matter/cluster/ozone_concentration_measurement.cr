require "./concentration_measurement_definition"

module Matter
  module Cluster
    # Matter 1.6 OzoneConcentrationMeasurement (revision 5).
    class OzoneConcentrationMeasurement < Base
      cluster 0x0415, revision: 5
      include ConcentrationMeasurementDefinition
      attribute 0x0009, :measurement_medium, MeasurementMedium, default: MeasurementMedium::Air, fixed: true
    end
  end
end
