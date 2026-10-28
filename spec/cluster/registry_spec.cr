require "../spec_helper"

# A manufacturer-specific id no cluster in `src/` or the specs declares.
private UNREGISTERED_ID = 0xFFF1_FCFE_u32

describe Matter::Cluster::Registry do
  {% for klass in Matter::Cluster::Base.subclasses %}
    {% if klass.name.starts_with?("Matter::Cluster::") && !klass.annotation(::Matter::Cluster::RegistryExclude) %}
      it "registers {{ klass }} under its CLUSTER_ID" do
        Matter::Cluster::Registry.for({{ klass }}::CLUSTER_ID).should eq({{ klass }})
      end
    {% end %}
  {% end %}

  it "keeps the standard Administrator Commissioning implementation as the default" do
    Matter::Cluster::Registry.for(Matter::Cluster::AdministratorCommissioning::CLUSTER_ID)
      .should eq(Matter::Cluster::AdministratorCommissioning)
  end

  it "answers nil for an id no cluster declares" do
    Matter::Cluster::Registry.for(UNREGISTERED_ID).should be_nil
  end

  it "lists the registered ids in ascending order" do
    ids = Matter::Cluster::Registry.ids
    ids.should eq(ids.sort)
    ids.should contain(Matter::Cluster::OnOff::CLUSTER_ID)
    ids.should_not contain(UNREGISTERED_ID)
  end

  it "yields every registered id with its class" do
    seen = {} of UInt32 => Matter::Cluster::Base.class
    Matter::Cluster::Registry.each { |id, klass| seen[id] = klass }
    seen.keys.should eq(Matter::Cluster::Registry.ids)
    seen.each { |id, klass| Matter::Cluster::Registry.for(id).should eq(klass) }
  end
end
