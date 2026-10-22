module MatterMotionSensor
  # Applies the configured HoldTime to simulated raw motion samples. Real
  # sensors may apply their own detection filtering before calling the cluster.
  class MotionHold
    @last_detection : Time::Instant?
    @occupied = false

    # Returns a new occupancy state only when the processed state changes.
    def sample(detected : Bool, hold_time : UInt16, now : Time::Instant = Time.instant) : Bool?
      if detected
        @last_detection = now
        unless @occupied
          @occupied = true
          return true
        end
      elsif @occupied
        if last_detection = @last_detection
          if now - last_detection >= hold_time.seconds
            @occupied = false
            @last_detection = nil
            return false
          end
        end
      end
      nil
    end
  end
end
