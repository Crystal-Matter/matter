require "../storage/document"

module Matter
  module Commissioning
    # The live commissioning state a failsafe rollback restores.
    #
    # `FailsafeContext` records snapshots but holds no reference to the objects
    # that own the live state, so a rollback is handed a target instead. Keeping
    # this an interface is what lets `commissioning/` compile without requiring
    # any cluster: `Cluster::GeneralCommissioning` includes it.
    module RollbackTargets
      # Restore the network configuration captured in `snapshot`.
      abstract def restore_network_state(snapshot : Storage::Document) : Nil

      # Commit provisional network configuration before disarming the fail-safe.
      abstract def commit_network_state : Nil

      # Restore the regulatory configuration captured before SetRegulatoryConfig.
      abstract def restore_regulatory_config(location_type : UInt8, country_code : String) : Nil

      # Close a commissioning window opened during the failsafe.
      abstract def close_commissioning_window : Nil
    end

    # Network configuration a failsafe rollback can restore, implemented by
    # `Cluster::NetworkCommissioning`. A `RollbackTargets` implementation that
    # does not own the network configuration itself forwards to one of these.
    module NetworkStateStore
      abstract def restore_network_state(snapshot : Storage::Document) : Nil
      abstract def commit_network_state : Nil
    end
  end
end
