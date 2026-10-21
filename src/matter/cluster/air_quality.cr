require "./cluster"

module Matter
  module Cluster
    # Qualitative air quality with optional intermediate levels.
    class AirQuality < Base
      cluster 0x005B, revision: 1

      feature :fair, bit: 0
      feature :moderate, bit: 1
      feature :very_poor, bit: 2
      feature :extremely_poor, bit: 3

      enum Level : UInt8
        Unknown       = 0
        Good          = 1
        Fair          = 2
        Moderate      = 3
        Poor          = 4
        VeryPoor      = 5
        ExtremelyPoor = 6
      end

      attribute 0x0000, :air_quality, Level, default: Level::Unknown

      def initialize(endpoint_id : DataType::EndpointNumber,
                     @feature_map : Feature = Feature::None,
                     @air_quality : Level = Level::Unknown)
        super(endpoint_id, DataType::ClusterId.new(CLUSTER_ID))
        validate_level!(@air_quality)
      end

      # Publishes a new sensor assessment, rejecting unadvertised optional levels.
      def update_quality(level : Level) : Nil
        validate_level!(level)
        self.air_quality = level
      end

      private def validate_level!(level : Level) : Nil
        enabled = case level
                  when .fair?           then @feature_map.fair?
                  when .moderate?       then @feature_map.moderate?
                  when .very_poor?      then @feature_map.very_poor?
                  when .extremely_poor? then @feature_map.extremely_poor?
                  else                       true
                  end
        raise ArgumentError.new("#{level} air quality requires its feature") unless enabled
      end
    end
  end
end
