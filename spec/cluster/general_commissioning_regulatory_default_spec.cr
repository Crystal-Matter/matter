require "../support/general_commissioning_helpers"

module Matter::Cluster
  describe GeneralCommissioning do
    # Matter 1.6 GeneralCommissioningCluster.xml gives RegulatoryConfig
    # the initial value of the fixed LocationCapability attribute.
    it "reports the configured Indoor-only regulatory default over IM" do
      cluster = build(GeneralCommissioning, 0,
        location_capability: GeneralCommissioning::RegulatoryLocationType::Indoor)

      cluster.location_capability.should eq(GeneralCommissioning::RegulatoryLocationType::Indoor)
      cluster.regulatory_config.should eq(GeneralCommissioning::RegulatoryLocationType::Indoor)
      location = cluster.read_attribute(GeneralCommissioning::ATTR_LOCATION_CAPABILITY).as(TLV::Any)
      config = cluster.read_attribute(GeneralCommissioning::ATTR_REGULATORY_CONFIG).as(TLV::Any)
      location.value.should eq(GeneralCommissioning::RegulatoryLocationType::Indoor.value)
      config.value.should eq(GeneralCommissioning::RegulatoryLocationType::Indoor.value)
    end

    it "keeps the fixed manufacturer capability and regulatory default together" do
      cluster = build(GeneralCommissioning, 0,
        location_capability: GeneralCommissioning::RegulatoryLocationType::Indoor)

      expect_raises(Matter::ConfigurationError) do
        cluster.location_capability = GeneralCommissioning::RegulatoryLocationType::Outdoor
      end

      cluster.location_capability.should eq(GeneralCommissioning::RegulatoryLocationType::Indoor)
      cluster.regulatory_config.should eq(GeneralCommissioning::RegulatoryLocationType::Indoor)
    end

    it "retains an Indoor-only configured default after TC state restore" do
      cluster = build(GeneralCommissioning, 0,
        feature_map: GeneralCommissioning::Feature::TermsAndConditions,
        location_capability: GeneralCommissioning::RegulatoryLocationType::Indoor)
      saved = cluster.save_state
      saved.should_not be_nil

      restored = build(GeneralCommissioning, 0,
        feature_map: GeneralCommissioning::Feature::TermsAndConditions,
        location_capability: GeneralCommissioning::RegulatoryLocationType::Indoor)
      restored.restore_state(saved.as(Matter::Storage::Document))

      restored.location_capability.should eq(GeneralCommissioning::RegulatoryLocationType::Indoor)
      restored.regulatory_config.should eq(GeneralCommissioning::RegulatoryLocationType::Indoor)
      restored.read_attribute(GeneralCommissioning::ATTR_REGULATORY_CONFIG).as(TLV::Any).value
        .should eq(GeneralCommissioning::RegulatoryLocationType::Indoor.value)
    end
  end
end
