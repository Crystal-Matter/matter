require "../spec_helper"

describe Matter::Cluster::DoorLock do
  it "rejects Aliro feature advertisement until required reader configuration exists" do
    feature_map = Matter::Cluster::DoorLock::Feature::User |
                  Matter::Cluster::DoorLock::Feature::AliroProvisioning
    expect_raises(ArgumentError, /Aliro/) do
      build(Matter::Cluster::DoorLock, feature_map: feature_map)
    end
  end
end
